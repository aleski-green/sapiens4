module Host.Remote.Receipt (legacyJSON) where

import Control.Applicative ((<|>))
import Data.Aeson (Value(String), eitherDecodeStrict)
import Data.Char
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Numeric (floatToDigits, showHex)
import Text.ParserCombinators.ReadP
import Text.Read (readMaybe)
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

legacyJSON :: B.ByteString -> Either String B.ByteString
legacyJSON bytes = case [value | (value, rest) <- readP_to_S (spaces *> value <* spaces <* eof) (T.unpack $ TE.decodeUtf8 bytes), null rest] of
 [] -> Left "Cannot decode legacy receipt JSON"
 values -> Right $ TE.encodeUtf8 $ T.pack $ last values
 where
 spaces = skipMany (satisfy (`elem` (" \r\n\t" :: String)))
 token parser = parser <* spaces
 quoted = do
  (raw,_) <- gather $ char '"' *> many (satisfy (\c -> c /= '"' && c /= '\\') <|> (char '\\' *> get)) <* char '"'
  case eitherDecodeStrict (TE.encodeUtf8 $ T.pack raw) of
   Right (String decoded) -> pure (T.unpack decoded)
   _ -> pfail
 value = choice
  [ do fields <- between (token $ char '{') (char '}') $ sepBy ((,) <$> token quoted <*> (token (char ':') *> token value)) (token $ char ',')
       pure $ "{" ++ intercalate ", " [quote key ++ ": " ++ child | (key,child) <- M.toAscList $ M.fromList fields] ++ "}"
  , do children <- between (token $ char '[') (char ']') $ sepBy (token value) (token $ char ',')
       pure $ "[" ++ intercalate ", " children ++ "]"
  , quote <$> quoted
  , string "null", string "true", string "false"
  , do raw <- munch1 (`elem` ("-+0123456789.eE" :: String))
       if any (`elem` (".eE" :: String)) raw then maybe pfail (pure . floatJSON) (readMaybe raw)
        else maybe pfail (pure . show) (readMaybe raw :: Maybe Integer)
  ]

quote :: String -> String
quote value = '"' : concatMap escape value ++ "\""
 where
 escape '"' = "\\\""
 escape '\\' = "\\\\"
 escape '\b' = "\\b"
 escape '\f' = "\\f"
 escape '\n' = "\\n"
 escape '\r' = "\\r"
 escape '\t' = "\\t"
 escape char | ord char >= 32 && ord char < 127 = [char]
             | ord char <= 0xffff = unicode (ord char)
             | otherwise = let point = ord char - 0x10000 in unicode (0xd800 + point `div` 1024) ++ unicode (0xdc00 + point `mod` 1024)
 unicode code = let digits = showHex code "" in "\\u" ++ replicate (4-length digits) '0' ++ digits

floatJSON :: Double -> String
floatJSON number
 | isNaN number = "NaN"
 | isInfinite number = if number < 0 then "-Infinity" else "Infinity"
 | number == 0 = if isNegativeZero number then "-0.0" else "0.0"
 | otherwise = sign ++ format
 where
 sign = if number < 0 then "-" else ""
 (digits, exponent) = shortest (abs number)
 decimal = map intToDigit digits
 power = exponent - 1
 exponentText = (if power < 0 then "-" else "+") ++ let raw = show $ abs power in replicate (2-length raw) '0' ++ raw
 format
  | power < -4 || power >= 16 = take 1 decimal ++ (if length decimal > 1 then "." ++ drop 1 decimal else "") ++ "e" ++ exponentText
  | exponent <= 0 = "0." ++ replicate (-exponent) '0' ++ decimal
  | exponent >= length decimal = decimal ++ replicate (exponent-length decimal) '0' ++ ".0"
  | otherwise = take exponent decimal ++ "." ++ drop exponent decimal

shortest :: Double -> ([Int], Int)
shortest number = choose 1
 where
 decimalExponent = snd $ floatToDigits 10 number
 choose precision =
  let scale = decimalExponent - precision
      coefficient = round (toRational number / (10 ^^ scale)) :: Integer
      candidate = show coefficient ++ "e" ++ show scale
  in if (read candidate :: Double) == number || precision >= 17 then normalize coefficient scale else choose (precision + 1)
 normalize coefficient scale
  | coefficient `mod` 10 == 0 = normalize (coefficient `div` 10) (scale + 1)
  | otherwise = let digits = map digitToInt $ show coefficient in (digits, length digits + scale)

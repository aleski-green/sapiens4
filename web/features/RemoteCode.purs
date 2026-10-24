module Sapiens.RemoteCode (main) where

import Prelude
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (all, foldl)
import Data.Function.Uncurried (mkFn1)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (Nullable, toMaybe)
import Data.Number as Number
import Data.String as String
import Data.String.CodeUnits as CU
import Data.String.Regex as Regex
import Data.String.Regex.Flags (noFlags, global)
import Effect (Effect)
import Effect.Aff (Aff, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error, throw, try)
import Effect.Uncurried (mkEffectFn1, mkEffectFn3)
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object as Object
import Sapiens.Async (Promise, fromPromise, toPromise)
import Sapiens.Browser as Browser

foreign import encode64 :: String -> String
foreign import decode64 :: String -> Effect String
foreign import stringInput :: Foreign -> Nullable String
foreign import field :: String -> Foreign -> Foreign
foreign import parseJSON :: String -> Effect Foreign
foreign import parseURL :: String -> Effect { origin :: String, pathname :: String, search :: String, username :: String, password :: String, hash :: String }
foreign import radix36 :: Number -> String
foreign import parse36 :: String -> Number
foreign import decodeBytes :: String -> Effect (Array Int)
foreign import encodeBytes :: String -> Array Int
foreign import digest :: Array Int -> Effect (Promise (Array Int))
foreign import device :: Effect { userAgent :: String, maxTouchPoints :: Int, installed :: Boolean }

type Invitation =
  { relay :: String, room :: String, token :: String, secret :: String
  , desktop :: String, expires :: Number, public_id :: Nullable String }

type DeviceInfo = { name :: String, platform :: String, client :: String }

matches :: String -> String -> Boolean
matches pattern value = case Regex.regex pattern noFlags of
  Left _ -> false
  Right regex -> Regex.test regex value

replace :: String -> String -> String -> String
replace pattern replacement value = case Regex.regex pattern global of
  Left _ -> value
  Right regex -> Regex.replace regex replacement value

url64 :: String -> String
url64 = replace "=+$" "" <<< replace "/" "_" <<< replace "\\+" "-"

base64 :: String -> String
base64 value = replace "_" "/" (replace "-" "+" value) <>
  CU.fromCharArray (Array.replicate ((4 - CU.length value `mod` 4) `mod` 4) '=')

encode :: Invitation -> String
encode value = String.joinWith "." $
  [ "s4", url64 $ encode64 value.relay, value.room, value.token, value.secret
  , url64 value.desktop, radix36 $ Number.floor value.expires ] <>
  case toMaybe value.public_id of
    Just id | id /= "" -> [id]
    _ -> []

invalid :: String
invalid = "Use the QR from the host corpora’s New Pairing."

decode :: Foreign -> Effect Foreign
decode input = case toMaybe $ stringInput input of
  Nothing -> throw invalid
  Just value | CU.length value > 4096 -> throw invalid
  Just value -> do
    let trimmed = String.trim value
    if CU.take 1 trimmed == "{" then parseJSON value
    else if matches "^https?://" trimmed then do
      url <- parseURL trimmed
      invitation <- decode $ unsafeToForeign $ CU.drop 1 url.hash
      if toMaybe (stringInput $ field "relay" invitation) /= Just url.origin || url.pathname /= "/" ||
          url.search /= "" || url.username /= "" || url.password /= ""
        then throw "Invalid pairing link."
        else pure invitation
    else do
      let
        parts = String.split (String.Pattern ".") (replace "\\s" "" value)
        part index = fromMaybe "" $ Array.index parts index
        count = Array.length parts
        valid = Array.elem count [7, 8] && part 0 == "s4" &&
          (count /= 8 || matches "^sapi4_[a-z0-9]{9}$" (part 7)) &&
          all (matches "^[A-Za-z0-9_-]+$") (Array.slice 1 6 parts) &&
          matches "^[0-9a-z]{1,10}$" (part 6)
      unless valid $ throw invalid
      result <- try do
        relay <- decode64 $ base64 $ part 1
        let invitation = Object.fromHomogeneous
              { v: unsafeToForeign "sapiens-remote-box-v1", relay: unsafeToForeign relay
              , room: unsafeToForeign $ part 2, token: unsafeToForeign $ part 3, secret: unsafeToForeign $ part 4
              , desktop: unsafeToForeign $ base64 $ part 5, expires: unsafeToForeign $ parse36 $ part 6 }
        pure $ unsafeToForeign $ if count == 8 then Object.insert "public_id" (unsafeToForeign $ part 7) invitation else invitation
      case result of
        Left _ -> throw invalid
        Right invitation -> pure invitation

confirmation :: String -> String -> String -> Aff String
confirmation desktop phone room = do
  first <- liftEffect $ decodeBytes desktop
  second <- liftEffect $ decodeBytes phone
  unless (Array.length first == 32 && Array.length second == 32) $ throwError $ error "Invalid device key."
  promise <- liftEffect $ digest $ encodeBytes ("sapiens-confirm-v1\x0000" <> room <> "\x0000") <> first <> second
  hash <- fromPromise promise
  let
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"
    radix = Int.toNumber $ CU.length alphabet
    value = Number.remainder (foldl (\n byte -> n * 256.0 + Int.toNumber byte) 0.0 $ Array.take 6 hash) (Number.pow radix 8.0)
    digits 0 _ result = result
    digits count n result = digits (count - 1) (Number.floor $ n / radix)
      (CU.singleton (fromMaybe 'A' $ CU.charAt (Int.floor $ Number.remainder n radix) alphabet) <> result)
    code = digits 8 value ""
  pure $ CU.take 4 code <> " · " <> CU.drop 4 code

deviceInfo :: Effect DeviceInfo
deviceInfo = do
  info <- device
  let
    ua = info.userAgent
    ipad = matches "iPad" ua || (matches "Macintosh" ua && info.maxTouchPoints > 1)
    iphone = matches "iPhone" ua
    android = matches "Android" ua
    windows = matches "Windows" ua
    mac = matches "Macintosh" ua
    linux = matches "Linux" ua
    name | ipad = "iPad"
         | iphone = "iPhone"
         | android = "Android device"
         | windows = "Windows PC"
         | mac = "Mac"
         | linux = "Linux device"
         | otherwise = "Remote device"
    platform | ipad = "iPadOS"
             | iphone = "iOS"
             | name == "Mac" = "macOS"
             | name == "Windows PC" = "Windows"
             | name == "Android device" = "Android"
             | name == "Linux device" = "Linux"
             | otherwise = "Unknown platform"
    version = case Regex.regex "(?:CPU (?:iPhone )?OS|iPhone OS|Android|Windows NT|Mac OS X) ([\\d_.]+)" noFlags of
      Left _ -> Nothing
      Right regex -> Regex.match regex ua >>= (Array.index <@> 1) <<< Array.fromFoldable >>= identity
  pure { name, platform: platform <> maybeVersion version
       , client: if info.installed then "Sapiens4 Home Screen app" else "Sapiens4 browser" }
  where
  maybeVersion Nothing = ""
  maybeVersion (Just version) = " " <> replace "_" "." version

main :: Effect Unit
main = Browser.expose "RemoteCode"
  { encode: mkFn1 encode
  , decode: mkEffectFn1 decode
  , link: mkFn1 (\invitation -> invitation.relay <> "/#" <> encode invitation)
  , confirmation: mkEffectFn3 (\desktop phone room -> toPromise $ confirmation desktop phone room)
  , deviceInfo
  }

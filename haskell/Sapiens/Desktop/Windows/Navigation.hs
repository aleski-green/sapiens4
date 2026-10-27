{-# LANGUAGE OverloadedStrings #-}
module Sapiens.Desktop.Windows.Navigation (trusted, guest) where

import Data.Char (toLower)
import Data.List (isPrefixOf)
import Network.URI (URI(..), URIAuth(..), parseURI)

trusted :: String -> String -> Bool
trusted origin value = case (parseURI origin, parseURI value) of
  (Just a, Just b) -> scheme a == scheme b && authority a == authority b &&
    noCredentials b && uriPath b `elem` ["/workspace", "/workspace/"]
  _ -> False

guest :: String -> String -> Bool
guest _ "about:blank" = True
guest origin value = case parseURI value of
  Just uri | noCredentials uri -> case scheme uri of
    "file:" -> loopback uri
    protocol | protocol `elem` ["http:", "https:"] ->
      maybe True (\local -> port local /= port uri || not (loopback uri)) (parseURI origin)
    _ -> False
  _ -> False

scheme :: URI -> String
scheme = map toLower . uriScheme

authority :: URI -> (String, String)
authority uri = (maybe "" (map toLower . uriRegName) (uriAuthority uri), port uri)

port :: URI -> String
port uri = case uriAuthority uri >>= \a -> if null (uriPort a) then Nothing else Just (uriPort a) of
  Just p -> p
  Nothing -> if scheme uri == "https:" then ":443" else ":80"

noCredentials :: URI -> Bool
noCredentials = maybe True (null . uriUserInfo) . uriAuthority

loopback :: URI -> Bool
loopback uri = let host = fst (authority uri)
  in host `elem` ["", "localhost", "[::1]"] || "127." `isPrefixOf` host

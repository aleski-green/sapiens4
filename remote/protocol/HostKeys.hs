module HostKeys (HostKeys(..), KeysPlan(..), hostKeysKey, planHostKeys, readHostKeys) where

import Config (boxKeyBytes)
import Crypto (decodeBase64)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)

data HostKeys = HostKeys { hostPrivate :: Text, hostPublic :: Text, hostDevice :: Maybe Text }
 deriving (Eq, Show)

instance ToJSON HostKeys where
 toJSON keys = object
  ["private" .= hostPrivate keys, "public" .= hostPublic keys, "device" .= hostDevice keys]

instance FromJSON HostKeys where
 parseJSON = withObject "HostKeys"
  (\o -> HostKeys <$> o .: "private" <*> o .: "public" <*> o .:? "device")

data KeysPlan = KeepKeys HostKeys | AdoptKeys HostKeys | MakeKeys deriving (Eq, Show)

hostKeysKey :: Text
hostKeysKey = "local/identity"

readHostKeys :: Value -> Maybe HostKeys
readHostKeys = parseMaybe parseJSON

planHostKeys :: Maybe Text -> Maybe HostKeys -> Maybe HostKeys -> KeysPlan
planHostKeys machine saved pairing = case (saved, pairing) of
 (Just keys, _) | valid keys -> KeepKeys keys
 (Just _, _) -> MakeKeys
 (Nothing, Just keys) | valid keys -> AdoptKeys keys { hostDevice = machine }
 (Nothing, _) -> MakeKeys
 where
 valid keys = sameMachine (hostDevice keys) && all wellFormed [hostPrivate keys, hostPublic keys]
 sameMachine stored = case (machine, stored) of
  (Just now, Just before) -> now == before
  (Just _, Nothing) -> True
  (Nothing, _) -> True
 wellFormed key = either (const False) (const True) (decodeBase64 (String key) (Just boxKeyBytes))

module Environment
 ( DeviceSource(..), DeviceIdentity, nativeOS, readNativeDevice, parseDeviceIdentity, deviceFields
 , EnvironmentId(..), EnvironmentRecord(..), deviceKey, sameDevice ) where

import Control.Exception
import Crypto.Hash.SHA256 (hmac)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import Data.Char (isHexDigit)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.UUID as UUID
import Numeric (showHex)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..))
import System.Info (os)
import System.Process
import System.Timeout (timeout)

data DeviceSource = MacPlatformUUID | WindowsSMBIOSUUID | LinuxMachineID deriving (Eq, Show)
data DeviceIdentity = DeviceIdentity DeviceSource Text deriving Eq

newtype EnvironmentId = EnvironmentId Text deriving (Eq, Show)
instance ToJSON EnvironmentId where
 toJSON (EnvironmentId key) = String key
instance FromJSON EnvironmentId where
 parseJSON = withText "Environment ID" (pure . EnvironmentId)

data EnvironmentRecord = EnvironmentRecord { environmentId :: EnvironmentId, environmentDevice :: Maybe Text } deriving (Eq, Show)
instance ToJSON EnvironmentRecord where
 toJSON record = object ["id" .= environmentId record, "device" .= environmentDevice record]
instance FromJSON EnvironmentRecord where
 parseJSON = withObject "Environment" (\o -> EnvironmentRecord <$> o .: "id" <*> o .:? "device")

deviceKey :: DeviceIdentity -> Text
deviceKey (DeviceIdentity _ key) = key

sameDevice :: Maybe Text -> EnvironmentRecord -> Bool
sameDevice current record = case (current, environmentDevice record) of
 (Just now, Just saved) -> now == saved
 (Just _, Nothing) -> True
 (Nothing, _) -> True

sourceName :: DeviceSource -> Text
sourceName source = case source of
 MacPlatformUUID -> "macos_platform_uuid"
 WindowsSMBIOSUUID -> "windows_smbios_uuid"
 LinuxMachineID -> "linux_machine_id"

nativeOS :: Text
nativeOS = case os of "darwin" -> "macos"; "mingw32" -> "windows"; "linux" -> "linux"; _ -> "unknown"

deviceFields :: Text -> Maybe DeviceIdentity -> Object
deviceFields prefix identity = KM.fromList
 [(K.fromText (prefix<>"device_id"),maybe Null (\(DeviceIdentity _ key) -> String key) identity)
 ,(K.fromText (prefix<>"device_id_source"),maybe Null (\(DeviceIdentity source _) -> String (sourceName source)) identity)]

parseDeviceIdentity :: Value -> Value -> Maybe DeviceIdentity
parseDeviceIdentity (String key) (String name) = do
 source <- lookup name [(sourceName source,source) | source <- [MacPlatformUUID,WindowsSMBIOSUUID,LinuxMachineID]]
 if T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key then Just (DeviceIdentity source key) else Nothing
parseDeviceIdentity _ _ = Nothing

deviceNamespace :: B.ByteString
deviceNamespace = "sapiens4.telemetry.device.v1:"

deriveDevice :: DeviceSource -> Text -> Maybe DeviceIdentity
deriveDevice source input = do
 normalized <- if source==LinuxMachineID then Just (T.toLower (T.strip input))
  else T.filter (/='-') . UUID.toText <$> UUID.fromText (T.strip input)
 if T.length normalized/=32 || not (T.all isHexDigit normalized) || T.all (=='0') normalized || T.all (=='f') normalized then Nothing
 else let digest = hmac (TE.encodeUtf8 normalized) (deviceNamespace<>TE.encodeUtf8 (sourceName source))
          hex byte = let value=showHex byte "" in if length value==1 then '0':value else value
      in Just (DeviceIdentity source (T.pack (concatMap hex (B.unpack digest))))

nativeLookupTimeoutMicros :: Int
nativeLookupTimeoutMicros = 2 * 1000000

readNativeDevice :: IO (Maybe DeviceIdentity)
readNativeDevice = do
 result <- timeout nativeLookupTimeoutMicros (lookupDevice `catch` \(_::IOException) -> pure Nothing)
 pure (result >>= id)
 where
 command binary arguments = do
  environment <- filter ((/="PSModulePath") . fst) <$> getEnvironment
  (status,output,_) <- readCreateProcessWithExitCode (proc binary arguments)
   {env=Just environment,use_process_jobs=True,detach_console=os=="mingw32"} ""
  pure (if status==ExitSuccess then Just (T.strip (T.pack output)) else Nothing)
 lookupDevice = case os of
  "darwin" -> do
   output <- command "/usr/sbin/ioreg" ["-rd1","-c","IOPlatformExpertDevice"]
   let extract line = case T.splitOn "\"" line of
        _:"IOPlatformUUID":_:value:_ -> Just value
        _ -> Nothing
   pure (output >>= listToMaybe . mapMaybe extract . T.lines >>= deriveDevice MacPlatformUUID)
  "mingw32" -> do
   output <- command "powershell.exe" ["-NoProfile","-NonInteractive","-Command","$ErrorActionPreference='Stop'; (Get-CimInstance -ClassName Win32_ComputerSystemProduct -Property UUID).UUID"]
   pure (output >>= deriveDevice WindowsSMBIOSUUID)
  "linux" -> either (const Nothing) (deriveDevice LinuxMachineID) . TE.decodeUtf8' <$> B.readFile "/etc/machine-id"
  _ -> pure Nothing

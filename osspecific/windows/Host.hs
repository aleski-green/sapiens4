{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Host (Host(..), prepareHost, startHost, closeHost) where

import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.Aeson
import Data.IORef
import Data.List (stripPrefix)
import Data.Maybe
import Network.HTTP.Client
import Network.URI
import Native (processId)
import System.Directory
import System.Environment
import System.FilePath
import System.IO
import System.Process
import System.Timeout
import qualified Data.Aeson.KeyMap as K

data Host = Host
  { dataDirectory :: FilePath
  , runtimeDirectory :: FilePath
  , serverProcess :: IORef (Maybe (ProcessHandle, Handle, Async ()))
  , origin :: IORef String
  }

prepareHost :: [String] -> IO Host
prepareHost args = do
  executable <- getExecutablePath
  local <- lookupEnv "LOCALAPPDATA" >>= maybe getHomeDirectory pure
  dataEnv <- lookupEnv "SAPIENS_DATA_DIR"
  runtimeEnv <- lookupEnv "SAPIENS_RUNTIME_DIR"
  let option name = listToMaybe [value | (key, value) <- zip args (drop 1 args), key == name]
  directory <- makeAbsolute $ fromMaybe (local </> "Sapiens4") (option "--data-dir" `mplus` dataEnv)
  runtime <- makeAbsolute $ fromMaybe (takeDirectory executable </> "runtime") (option "--runtime-dir" `mplus` runtimeEnv)
  Host directory runtime <$> newIORef Nothing <*> newIORef ""

startHost :: Host -> IO String
startHost host = do
  createDirectoryIfMissing True (dataDirectory host)
  let binary = runtimeDirectory host </> ".build/bin/sapiens4.exe"
  available <- doesFileExist binary
  unless available $ ioError $ userError $ "Haskell runtime is missing. Extract the complete Sapiens4 package: " ++ binary
  environment <- getEnvironment
  pid <- processId
  (Just input, Just output, Just errors, child) <- createProcess (proc binary ["--port", "0", "--data-dir", dataDirectory host, "--desktop"])
    { cwd = Just (runtimeDirectory host), std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe
    , env = Just (("SAPIENS_DESKTOP_PID", show pid) : filter ((/= "SAPIENS_DESKTOP_PID") . fst) environment)
    , create_group = True, use_process_jobs = True, detach_console = True }
  mapM_ (\stream -> hSetEncoding stream utf8 >> hSetNewlineMode stream universalNewlineMode) [input, output, errors]
  errorText <- newIORef ""
  collect <- async $ (forever $ hGetLine errors >>= \line -> modifyIORef' errorText (\old -> let next = old ++ line ++ "\n" in drop (max 0 $ length next - 12000) next))
    `catch` \(_ :: IOException) -> pure ()
  writeIORef (serverProcess host) (Just (child, input, collect))
  let ready = do
        ended <- hIsEOF output
        when ended $ readIORef errorText >>= ioError . userError . ("Sapiens4 server stopped. " ++)
        line <- hGetLine output
        case stripPrefix "Sapiens4: " line >>= parseURI of
          Just uri | uriScheme uri == "http:", Just auth <- uriAuthority uri, uriRegName auth == "127.0.0.1", null (uriUserInfo auth) -> pure uri
          _ -> ready
  result <- timeout 35000000 ready
  uri <- maybe (ioError $ userError "Sapiens4 did not become ready within 35 seconds") pure result
  let base = show uri { uriPath = "", uriQuery = "", uriFragment = "" }
  writeIORef (origin host) base
  manager <- newManager defaultManagerSettings
  request <- parseRequest (base ++ "/api/health")
  response <- httpLbs request { responseTimeout = responseTimeoutMicro 10000000 } manager
  case decode (responseBody response) of
    Just (Object fields) | K.lookup "status" fields == Just (String "ok") -> pure (show uri)
    _ -> ioError $ userError "Server readiness check failed"

closeHost :: Host -> IO ()
closeHost host = atomicModifyIORef' (serverProcess host) (\value -> (Nothing, value)) >>= mapM_ stop
  where
    stop (process, input, reader) = do
      (hPutStrLn input "stop" >> hFlush input >> hClose input) `catch` \(_ :: IOException) -> pure ()
      result <- timeout 10000000 (waitForProcess process)
      when (isNothing result) $ do
        terminateProcess process `catch` \(_ :: IOException) -> pure ()
      cancel reader

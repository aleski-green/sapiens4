{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module Sapiens.Types where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
import Data.Typeable
import Data.Word (Word64)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.Vector as V
import System.Directory
import System.FileLock
import System.FilePath
import System.IO
import System.Process
import System.IO.Error
#ifdef mingw32_HOST_OS
import Foreign.C
foreign import ccall unsafe "_wopen" syncOpen :: CWString -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "_commit" syncCommit :: CInt -> IO CInt
foreign import ccall unsafe "_close" syncClose :: CInt -> IO CInt
#else
import qualified System.Posix.IO as Posix
import qualified System.Posix.Unistd as Posix
#endif


data APIError = APIError Int Text deriving (Show, Typeable)
instance Exception APIError

data RunFailure = RunFailure Text [Value] deriving (Show,Typeable)
instance Exception RunFailure

data Run = Run { runOwner :: Text, runId :: Text, runSlot :: Int, runCancel :: IORef Bool, runProcess :: MVar (Maybe ProcessHandle), runActivity :: IORef Value, runDeadline :: Word64 }
data Service = Service { serviceRoot :: FilePath, repositoryRoot :: FilePath, serviceGuard :: MVar (), serviceFileLock :: FileLock, serviceStopping :: IORef Bool, serviceWorker :: MVar (Maybe (Async ())), serviceRuns :: MVar (Map Text Run), serviceLease :: IORef (Maybe (Text, Text)), serviceEndpoint :: IORef Text, servicePulse :: IORef Value, serviceActors :: MVar (Map ThreadId (Text,Maybe Text)) }

obj :: [(Text, Value)] -> Value
obj = Object . KM.fromList . map (\(k,v) -> (K.fromText k,v))
arr :: [Value] -> Value
arr = Array . V.fromList
str :: Text -> Value
str = String
num :: Int -> Value
num = toJSON
get :: Value -> Text -> Value
get (Object o) k = fromMaybe Null (KM.lookup (K.fromText k) o)
get _ _ = Null
text :: Value -> Text
text (String s) = s
text _ = ""
int :: Value -> Int
int (Number n) = fromMaybe 0 (toBoundedInteger n)
int _ = 0
boolean :: Value -> Bool
boolean (Bool b) = b
boolean _ = False
list :: Value -> [Value]
list (Array a) = V.toList a
list _ = []
pairs :: Value -> [(Text,Value)]
pairs (Object o) = map (\(k,v) -> (K.toText k,v)) (KM.toList o)
pairs _ = []
keys :: Value -> [Text]
keys = map fst . pairs
has :: Value -> Text -> Bool
has (Object o) k = KM.member (K.fromText k) o
has _ _ = False
put :: Text -> Value -> Value -> Value
put k v (Object o) = Object (KM.insert (K.fromText k) v o)
put k v _ = obj [(k,v)]
merge :: Value -> Value -> Value
merge a b = foldl (\x (k,v) -> put k v x) a (pairs b)
remove :: [Text] -> Value -> Value
remove ks = obj . filter ((`notElem` ks) . fst) . pairs
at :: Value -> Text -> Text
at v = text . get v
items :: Value -> Text -> [Value]
items v = list . get v
fallback :: Value -> Value -> Value
fallback Null b = b
fallback a _ = a
empty :: Value
empty = obj []
jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BL.toStrict . encode
parseJSONText :: Text -> Value
parseJSONText = fromMaybe Null . decode . BL.fromStrict . TE.encodeUtf8
failure :: Int -> Text -> IO a
failure n = throwIO . APIError n
require :: Bool -> Int -> Text -> IO ()
require p n m = unless p (failure n m)
textField :: Value -> Text -> Int -> IO Text
textField v k n = case get v k of
 String s | not (T.null (T.strip s)) && T.length s <= n -> pure (T.strip s)
 _ -> failure 400 (k <> " must be nonempty text, at most " <> T.pack (show n) <> " characters")
now :: IO Text
now = timestamp <$> getCurrentTime
timestamp :: UTCTime -> Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q+00:00"
parseTime :: Text -> Maybe UTCTime
parseTime s = parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Ez" (T.unpack s)
newId :: IO Text
newId = T.filter (/= '-') . UUID.toText <$> UUID.nextRandom
fresh :: Text -> IO Text
fresh prefix = (prefix <>) . T.take 12 <$> newId
readJSON :: FilePath -> Value -> IO Value
readJSON p def = do
 exists <- doesFileExist p
 if exists then either (throwIO . userError) pure . eitherDecode =<< BL.readFile p else pure def
atomicBytes :: FilePath -> BL.ByteString -> IO ()
atomicBytes p bytes = do
 createDirectoryIfMissing True (takeDirectory p)
 bracketOnError (openBinaryTempFile (takeDirectory p) ".writing-") (\(f,h) -> do
  hClose h `catch` (\(_::IOException) -> pure ())
  removeFile f `catch` (\(_::IOException) -> pure ())) $ \(f,h) -> do
  BL.hPut h bytes
  hFlush h
#ifdef mingw32_HOST_OS
  hClose h
  withCWString f $ \name -> bracket (syncOpen name 32770 0) (void . syncClose) $ \fd -> do
   require (fd >= 0) 500 "Cannot open durable temporary file"
   code <- syncCommit fd
   require (code == 0) 500 "Cannot synchronize temporary file"
  let replace attempt = renameFile f p `catch` \(e::IOException) ->
       if isPermissionError e && attempt < (100::Int) then threadDelay 10000 >> replace (attempt+1) else throwIO e
  replace 0
#else
  fd <- Posix.handleToFd h
  Posix.fileSynchronise fd `finally` Posix.closeFd fd
  renameFile f p
  bracket (Posix.openFd (takeDirectory p) Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd Posix.fileSynchronise
#endif
writeJSON :: FilePath -> Value -> IO ()
writeJSON p = atomicBytes p . encode
locked :: Service -> IO a -> IO a
locked s = withMVar (serviceGuard s) . const
agentRoot :: Service -> Text -> FilePath
agentRoot s a = serviceRoot s </> "agentpy/agents" </> T.unpack a
workspaceRoot :: Service -> Text -> FilePath
workspaceRoot s a = serviceRoot s </> "workspaces" </> T.unpack a
agentState :: Service -> Text -> IO Value
agentState s a = readJSON (agentRoot s a </> "state.json") empty
saveState :: Service -> Text -> Value -> IO ()
saveState s a v = writeJSON (agentRoot s a </> "state.json") (put "revision" (num (int (get v "revision") + 1)) v)
modifyState :: Service -> Text -> (Value -> Value) -> IO ()
modifyState s a f = agentState s a >>= saveState s a . f
mapTurns :: (Value -> Value) -> Value -> Value
mapTurns f v = put "turns" (arr (map f (items v "turns"))) v
archivePath :: Service -> Text -> Text -> FilePath
archivePath s a k = serviceRoot s </> "agentpy/corpora/archive" </> T.unpack a </> T.unpack k <.> "json"
findId :: Text -> [Value] -> Maybe Value
findId i = find ((== i) . (`at` "id"))
readText :: FilePath -> IO Text
readText = fmap (TE.decodeUtf8 . BL.toStrict) . BL.readFile
writeText :: FilePath -> Text -> IO ()
writeText p = atomicBytes p . BL.fromStrict . TE.encodeUtf8
prompt :: Service -> Text -> IO Text
prompt s k = readText (repositoryRoot s </> "prompts" </> T.unpack k <.> "md")
render :: Text -> [(Text,Text)] -> Text
render = foldl (\t (k,v) -> T.replace ("{" <> k <> "}") v t)

withActor :: Service -> Text -> Maybe Text -> IO a -> IO a
withActor s actor agency action = do
 thread <- myThreadId
 bracket (modifyMVar (serviceActors s) (\actors -> pure (M.insert thread (actor,agency) actors,M.lookup thread actors)))
  (\previous -> modifyMVar_ (serviceActors s) (pure . maybe (M.delete thread) (M.insert thread) previous)) (const action)
currentActor :: Service -> IO (Text,Maybe Text)
currentActor s = do
 thread <- myThreadId
 fromMaybe ("admin",Nothing) . M.lookup thread <$> readMVar (serviceActors s)

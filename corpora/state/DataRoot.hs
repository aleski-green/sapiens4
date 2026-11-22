{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
module DataRoot (module DataRoot, module RuntimePaths) where

import Types (writeJSON)
import RuntimePaths
import UpdateState (assertDataAvailable)
import Control.Exception
import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.Aeson.KeyMap as K
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.List (isPrefixOf)
import Data.Char (isAscii, isAlphaNum)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import BuildVersion
import qualified KV
import Domain (CorporaConfig)
import Network.URI (escapeURIString, isUnreserved)
import System.Directory
import System.FilePath
import System.FileLock
import System.IO
import System.IO.Error (ioeGetErrorString, isAlreadyExistsError, isUserError)
import System.Info (os)
#ifndef mingw32_HOST_OS
import qualified System.Posix.Directory as Posix
#endif

data StorageChoice = StartNew | AttachExisting | AttachChild FilePath T.Text | CreateCorpora deriving (Eq, Show)

selectionPath :: IO FilePath
selectionPath = configDirectory >>= \root -> containedPath root (root </> "storage.json")

savedDataDirectory :: IO (Maybe FilePath)
savedDataDirectory = do
 path <- selectionPath
 exists <- doesFileExist path
 if not exists then pure Nothing else do
  value <- either (ioError . userError . ("Could not read saved storage: " ++)) pure . eitherDecode =<< L.readFile path
  case value of
   Object fields | Just (Number 1) <- K.lookup "version" fields, Just (String folder) <- K.lookup "directory" fields, isAbsolute (T.unpack folder) -> Just <$> externalStoragePath (T.unpack folder)
   _ -> ioError (userError "Saved storage settings are incompatible. Choose your data directory again.")

startupDataDirectory :: Maybe FilePath -> IO (Maybe FilePath)
startupDataDirectory (Just explicit) = do
 when (null explicit) $ storageError "Data directory must not be empty"
 externalStoragePath explicit >>= populatedDataDirectory
startupDataDirectory Nothing = do
 saved <- savedDataDirectory
 case saved of
  Just directory -> pure (Just directory)
  Nothing -> defaultDataDirectory >>= populatedDataDirectory

populatedDataDirectory :: FilePath -> IO (Maybe FilePath)
populatedDataDirectory directory = do
 exists <- doesPathExist directory
 names <- if exists then listDirectory directory else pure []
 pure (if null (filter (/="host.lock") names) then Nothing else Just directory)

storageChoiceForDirectory :: FilePath -> IO StorageChoice
storageChoiceForDirectory directory = do
 names <- listDirectory directory
 pure (if null names then StartNew else AttachExisting)

saveDataDirectory :: FilePath -> IO ()
saveDataDirectory directory = do
 root <- externalStoragePath directory
 path <- selectionPath
 writeJSON path (object ["version" .= (1::Int), "directory" .= root])

makePrivateDirectory :: FilePath -> IO ()
#ifdef mingw32_HOST_OS
makePrivateDirectory = createDirectory
#else
makePrivateDirectory path = Posix.createDirectory path 0o700
#endif

createPrivateDirectory :: FilePath -> IO ()
createPrivateDirectory path = do
 exists <- doesDirectoryExist path
 unless exists $ do
  createDirectoryIfMissing True (takeDirectory path)
  makePrivateDirectory path `catch` \e -> unless (isAlreadyExistsError e) (throwIO e)

selectedPath :: StorageChoice -> FilePath -> IO FilePath
selectedPath choice directory = do
 root <- externalStoragePath directory
 case choice of
  AttachChild parent ident -> do
   expected <- childPath parent ident
   unless (equalFilePath expected root) $ storageError "The registered Corpora directory changed."
  _ -> pure ()
 pure root

childPath :: FilePath -> T.Text -> IO FilePath
childPath root ident = do
 unless ((UUID.toText <$> UUID.fromText ident) == Just ident) $ storageError "Invalid registered Corpora identity."
 folder <- containedPath root (root </> "corporas")
 containedPath folder (folder </> T.unpack ident)

checkWritableParent :: FilePath -> IO ()
checkWritableParent path = do
 dir <- doesDirectoryExist path
 if dir then do
  perms <- getPermissions path
  unless (writable perms && (os=="mingw32" || searchable perms)) $ storageError "The selected data directory is not writable."
 else do
  let parent = takeDirectory path
  when (path==parent) $ storageError "This data directory is unavailable."
  checkWritableParent parent

initializingDirectory :: FilePath -> FilePath
initializingDirectory root = root </> ".sapiens-initializing"

acquireStorage :: StorageChoice -> FilePath -> IO FileLock
acquireStorage choice root = do
 when (choice==StartNew) $ checkWritableParent root >> createPrivateDirectory root
 path <- containedPath root (root </> "host.lock")
 lockedBefore <- doesFileExist path
 unless lockedBefore $ validateDataRoot choice root
 bracketOnError (storageLock root) unlockFile $ \lock -> do
  location <- selectedPath choice root
  unless (equalFilePath location root) $ storageError "The selected data directory changed during startup."
  assertDataAvailable root
  validateDataRoot choice root
  names <- listDirectory root
  when (names==["host.lock"] && choice `elem` [StartNew,AttachExisting]) $
   makePrivateDirectory (initializingDirectory root)
  pure lock

storageLock :: FilePath -> IO FileLock
storageLock root = do
 path <- containedPath root (root </> "host.lock")
 tryLockFile path Exclusive >>= maybe
  (storageError "Another Sapiens4 server is using this data directory. Quit it before opening these data.") pure

withExistingLock :: FilePath -> IO a -> IO a
withExistingLock root action = do
 path <- containedPath root (root </> "host.lock")
 exists <- doesFileExist path
 if exists then bracket (storageLock root) unlockFile (const action) else action

storageMessage :: Exception e => e -> String
storageMessage errorValue = case fromException (toException errorValue) of
 Just err | isUserError err -> ioeGetErrorString err
 _ -> displayException errorValue

openingStorage, openedStorage, startupErrorPrefix :: String
openingStorage = "Sapiens4 storage: opening"
openedStorage = "Sapiens4 storage: opened"
startupErrorPrefix = "Sapiens4 startup error: "

startupMessage :: String
startupMessage = "Sapiens4 couldn't start. See desktop-server.log in the application configuration folder for details."

storageError :: String -> IO a
storageError = ioError . userError

readDataJSON :: FromJSON a => FilePath -> IO a
readDataJSON path = either (storageError . ("Could not read data: " ++)) pure . eitherDecode =<< L.readFile path

-- Startup validates the build contract. Only the explicit migration runner
-- transforms legacy roots; normal startup never upgrades data implicitly.
validateDataRoot :: StorageChoice -> FilePath -> IO ()
validateDataRoot choice root = do
 exists <- doesDirectoryExist root
 unless exists $ storageError "This data directory is unavailable."
 names <- listDirectory root
 let meaningful=filter (/="host.lock") names
     newRoot=null meaningful && choice `elem` [StartNew,AttachExisting]
     childSeed=choice==CreateCorpora && all (`elem` ["corpora-identity.json","corpora-settings.json","host.lock"]) names
 pending <- doesDirectoryExist (initializingDirectory root)
 when (choice==StartNew && not newRoot && not pending) $ storageError "Start fresh requires an empty data directory."
 forM_ ["state.lmdb","corpora-identity.json",dataBuildFile,"workspaces","uploads","host-corpora.json"] $ \name -> void (containedPath root (root </> name))
 unless (newRoot || childSeed || pending) $ do
  existsBuild <- doesFileExist (root </> dataBuildFile)
  unless existsBuild $ storageError "Data belong to v00.01.00. Apply the build migration before opening this workspace."
  build <- readDataJSON (root </> dataBuildFile) :: IO String
  unless (build==currentBuild) $ storageError "Data build differs from this app. Run the matching build migration or restore a backup."
  hasStore <- doesFileExist (root </> "state.lmdb/data.mdb")
  unless hasStore $ storageError "The LMDB store is missing. Restore the complete data root."
  identity <- readDataJSON (root </> "corpora-identity.json")
  case identity of
   Object fields | Just (String ident)<-K.lookup "corpora_id" fields, Just ident==(UUID.toText <$> UUID.fromText ident) -> case choice of
    AttachChild _ expected -> unless (ident==expected) $ storageError "Registered Corpora identity changed."
    _ -> pure ()
   _ -> storageError "Invalid CORPORA identity."

safeId :: T.Text -> Bool
safeId ident = not (T.null ident) && T.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("_-"::String))) ident

checkRegisteredIdentity :: FilePath -> T.Text -> IO ()
checkRegisteredIdentity child ident = do
 path <- containedPath child (child </> "corpora-identity.json")
 identity <- readDataJSON path
 unless (case identity of Object fields -> K.lookup "corpora_id" fields==Just (String ident); _ -> False) $
  storageError "A registered Corpora identity does not match its directory. Restore it from backup."

module Update
 ( UpdateBusy(..), UpdateHandoff(..), updateAndRestart, downloadUpdate, migrateCandidate, updateMode
 , candidateReady, reportCandidateFailure, preparingUpdate, tryUpdate, sendUpdateCommand
 , UpdateNotice(..), updateOffer, renderUpdateNotice
 ) where

import Control.Concurrent (Chan, MVar, readChan, withMVar)
import Control.Concurrent.Async (Async, race, waitCatch)
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Aeson
import Data.Either (isRight)
import Data.List (find, stripPrefix)
import Data.IORef
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Unique (hashUnique, newUnique)
import Numeric.Natural (Natural)
import Text.Read (readMaybe)
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import System.Directory hiding (executable)
import System.Environment
import System.Exit (exitFailure)
import System.FilePath
import System.IO
import System.Timeout (timeout)
import System.Process (callProcess)
import System.Info (os)
import Types (readJSON, writeJSON)
import UpdateState
import UpdatePlatform
import UpdateBackup
import Installation
import HostUpdateProtocol

tryUpdate :: IO a -> IO (Either SomeException a)
tryUpdate = tryJust $ \problem -> case fromException problem :: Maybe SomeAsyncException of
 Just _ -> Nothing
 Nothing -> Just problem

candidateReady :: (HostCommand -> IO (Maybe HostReply)) -> IO ()
candidateReady send = do
 preparing <- preparingUpdate
 when preparing $ do
  prepared <- send PrepareReady
  unless (prepared == Just Prepared) (fail "Candidate could not prepare the Workspace")
  reportMilestone CandidateReady
  command <- getLine
  unless (command == renderCoordinatorMessage Commit) (fail "Invalid Coordinator activation message")
  (root,version) <- installed
  state <- readUpdateState root
  unless (case state of Settled s -> current s == version; _ -> False) (fail "Candidate is not durably selected")
  active <- send Activate
  unless (active == Just Active) (fail "Candidate could not activate")
  unsetEnv "SAPIENS_UPDATE_ATTEMPT"
  reportMilestone CandidateActive `catch` \(_::IOException) -> pure ()

installed :: IO (FilePath,Version)
installed = installation >>= maybe (fail "Updates require an installed Sapiens version") pure

data ReleaseVersion = ReleaseVersion Natural Natural Natural deriving (Eq, Ord)

data Release = Release
 { releaseVersion :: ReleaseVersion
 , releaseURL :: String
 , releaseDigest :: Sha256
 }

data ReleaseAsset = ReleaseAsset
 { assetName :: String
 , assetURL :: String
 , assetDigest :: Maybe String
 }

data ReleaseFeed = ReleaseFeed T.Text [ReleaseAsset]

instance FromJSON ReleaseFeed where
 parseJSON = withObject "release" $ \o -> ReleaseFeed <$> o .: "tag_name" <*> (o .: "assets" >>= mapM asset)
  where
  asset = withObject "release asset" $ \o ->
   ReleaseAsset <$> o .: "name" <*> o .: "browser_download_url" <*> o .:? "digest"

data ReleaseError
 = InvalidReleaseVersion
 | AlreadyUpToDate
 | MissingPlatformPayload
 | UnexpectedDownloadOrigin
 | InvalidPayloadDigest
 deriving Show

instance Exception ReleaseError where
 displayException InvalidReleaseVersion = "Expected a release version in MAJOR.MINOR.PATCH format"
 displayException AlreadyUpToDate = "Sapiens is already up to date."
 displayException MissingPlatformPayload = "No update payload for this platform is available in the latest release"
 displayException UnexpectedDownloadOrigin = "Unexpected update download origin"
 displayException InvalidPayloadDigest = "Missing or invalid update payload SHA-256"

data UpdateBusy = UpdateBusy deriving Show
instance Exception UpdateBusy where
 displayException _ = "Sapiens is busy. Finish accepted work before updating."

sendUpdateCommand :: MVar () -> Handle -> Chan String -> Async () -> HostCommand -> IO (Maybe HostReply)
sendUpdateCommand commandLock input replies reader command = withMVar commandLock $ \_ -> do
 token <- show . hashUnique <$> newUnique
 hPutStrLn input (renderHostCommand command ++ " " ++ token)
 hFlush input
 let awaitReply = do
      (received,reply) <- break (==' ') <$> readChan replies
      if received == token then pure (drop 1 reply) else awaitReply
     response = race (waitCatch reader) awaitReply
 outcome <- case command of
  PrepareReady -> Just <$> response
  _ -> timeout 65000000 response
 case outcome of
  Just (Right reply) -> pure (parseHostReply reply)
  Just (Left _) -> fail "Application server exited during update coordination"
  Nothing -> fail "Application server did not respond to update coordination"

data UpdateHandoff = UpdateHandoff
 { showPreparing :: IO ()
 , commandHost :: HostCommand -> IO (Maybe HostReply)
 , savePreferences :: IO ()
 , stopHost :: IO ()
 }

updateAndRestart :: UpdateHandoff -> UpdateRoots -> IO ()
updateAndRestart handoff directories = do
 (root,owner) <- installed
 validateRoots root directories
 mask $ \unmask -> do
  staged <- readJSON (root </> "downloaded-update.json") Nothing
  (downloadOwner,next) <- maybe (fail "Download the update before installing it") pure staged
  unless (downloadOwner==owner && next/=owner) (fail "Downloaded update belongs to a different installed build")
  handoffStarted <- newIORef False
  result <- try $ do
   withCandidate (versionExecutable root owner) ["--update-coordinate",versionName next,dataRoot directories,configRoot directories] [] $ \coordinator -> do
    let quiet = requireIdle Quiesce "Sapiens could not pause safely. Update cancelled."
    (do
      unmask $ do
       showPreparing handoff
       await 15 coordinator CoordinatorListening
       (quiet >> savePreferences handoff) `onException` void (tryUpdate (commandHost handoff Resume))
       stopHost handoff
      candidateOwnership coordinator True)
     `onException` candidateOwnership coordinator False
    writeIORef handoffStarted True
    sendCandidate coordinator (renderCoordinatorMessage Handoff)
  case result of
   Right () -> pure ()
   Left problem -> do
    started <- readIORef handoffStarted
    unless started $ discardAfterStaging problem [versionPath root next]
    throwIO problem
 where
 requireIdle action message = commandHost handoff action >>= \reply -> case reply of
  Just Quiet -> pure ()
  Just Busy -> throwIO UpdateBusy
  _ -> fail message

requestUpdate :: FilePath -> Version -> Version -> IO ()
requestUpdate root owner next = mask $ \restore -> do
 result <- try $ restore $ do
  validatePath (root </> "versions")
  manager <- newManager tlsManagerSettings
  release <- discoverRelease manager root owner
  transfer <- parseRequest (releaseURL release)
  withResponse transfer manager $ \result -> withBinaryFile payload WriteMode $ \file ->
   let loop = do chunk <- brRead (responseBody result); unless (B.null chunk) (B.hPut file chunk >> loop)
   in loop
  validatePath payload
  verifyPayloadDigest (releaseDigest release) payload
  stagePayload (versionExecutable root owner) payload (versionPath root next)
  staged <- installedVersion root next
  unless (staged == releaseVersion release) (fail "Update payload version differs from the release tag")
 case result of
  Right () -> discard [payload]
  Left problem -> discardAfterStaging problem [payload] >> throwIO problem
 where payload = root </> (versionName next ++ "-" ++ payloadName)

discardAfterStaging :: SomeException -> [FilePath] -> IO ()
discardAfterStaging problem paths = case fromException problem of
 Just (_::StagingNotJoined) -> pure ()
 Nothing -> discard paths

verifyPayloadDigest :: Sha256 -> FilePath -> IO ()
verifyPayloadDigest expected path = withBinaryFile path ReadMode $ \file -> do
 digest <- sha256 <$> BL.hGetContents file
 unless (digest == expected) (fail "Update payload SHA-256 differs from the release")

data UpdateNotice = OfferAvailable | OfferHidden | DownloadReady | UpdatePreparing | UpdateBlocked | UpdateFailed

renderUpdateNotice :: UpdateNotice -> T.Text
renderUpdateNotice notice = case notice of
 OfferAvailable -> "available"
 OfferHidden -> "none"
 DownloadReady -> "downloaded"
 UpdatePreparing -> "updating"
 UpdateBlocked -> "busy"
 UpdateFailed -> "error"

-- Download and install have separate explicit user actions.
downloadUpdate :: IO ()
downloadUpdate = do
 (root,owner) <- installed
 next <- freshVersion
 requestUpdate root owner next
 writeJSON (root </> "downloaded-update.json") (owner,next)

updateOffer :: IO UpdateNotice
updateOffer = do
 result <- tryUpdate $ do
  (root,owner) <- installed
  staged <- readJSON (root </> "downloaded-update.json") Nothing
  valid <- case staged of
   Just (saved,next) | saved==owner && next/=owner -> doesFileExist (versionExecutable root next)
   _ -> pure False
  if valid then pure DownloadReady else do
   manager <- newManager tlsManagerSettings
   void (discoverRelease manager root owner)
   pure OfferAvailable
 pure (either (const OfferHidden) id result)

-- Compatibility bridge for the v00.01.00 coordinator: it already owns a verified
-- backup and Pending decision. Run the new build's explicit migration executable
-- before starting its host. Normal launches never invoke migration scripts.
migrateCandidate :: FilePath -> FilePath -> FilePath -> IO ()
migrateCandidate runtime dataDirectory configDirectory = do
 preparing <- preparingUpdate
 when preparing $ do
  authorized <- checkCandidateData dataDirectory
  unless authorized (fail "Migration requires a reserved update data root")
  let runner=runtime </> ".build/bin" </> ("sapiens-migrate"++if os=="mingw32" then ".exe" else "")
  callProcess runner ["--data-root",dataDirectory,"--config-root",configDirectory]

installedVersion :: FilePath -> Version -> IO ReleaseVersion
installedVersion root version =
 readFile (versionPath root version </> "sapiens-release.version") >>= either throwIO pure . parseReleaseVersion . T.pack

discoverRelease :: Manager -> FilePath -> Version -> IO Release
discoverRelease manager root owner = do
 installedRelease <- installedVersion root owner
 request <- parseRequest ("https://api.github.com/repos/" ++ releaseRepository ++ "/releases/latest")
 body <- responseBody <$> httpLbs request {requestHeaders=[("User-Agent","Sapiens4-Updater"),("Accept","application/vnd.github+json")]} manager
 feed <- either fail pure (eitherDecode body)
 either throwIO pure (selectRelease installedRelease payloadName feed)

releaseRepository :: String
releaseRepository = "aleski-green/sapiens4"

selectRelease :: ReleaseVersion -> String -> ReleaseFeed -> Either ReleaseError Release
selectRelease installedRelease platformPayload (ReleaseFeed tag assets) = do
 available <- parseReleaseVersion tag
 unless (available > installedRelease) (Left AlreadyUpToDate)
 asset <- maybe (Left MissingPlatformPayload) Right (find ((== platformPayload) . assetName) assets)
 let expectedURL = "https://github.com/" ++ releaseRepository ++ "/releases/download/" ++ T.unpack tag ++ "/" ++ platformPayload
 unless (assetURL asset == expectedURL) (Left UnexpectedDownloadOrigin)
 case assetDigest asset >>= stripPrefix "sha256:" >>= parseSha256 of
  Just digest -> Right (Release available expectedURL digest)
  _ -> Left InvalidPayloadDigest

parseReleaseVersion :: T.Text -> Either ReleaseError ReleaseVersion
parseReleaseVersion input =
 case traverse component (T.splitOn "." (fromMaybe trimmed (T.stripPrefix "v" trimmed))) of
  Just [major,minor,patch] -> Right (ReleaseVersion major minor patch)
  _ -> Left InvalidReleaseVersion
 where
 trimmed = T.stripEnd input
 component field
  | T.all (\c -> c >= '0' && c <= '9') field = readMaybe (T.unpack field)
  | otherwise = Nothing

data CoordinatorIntent
 = RecoverOrLaunch
 | StartStaged { stagedVersion :: Version, stagedRoots :: UpdateRoots }

data CoordinatorMessage = Handoff | Commit

renderCoordinatorMessage :: CoordinatorMessage -> String
renderCoordinatorMessage Handoff = "handoff"
renderCoordinatorMessage Commit = "commit"

data Milestone = CoordinatorListening | CandidateReady | CandidateActive

renderMilestone :: Milestone -> String
renderMilestone CoordinatorListening = "update: coordinator"
renderMilestone CandidateReady = "update: ready"
renderMilestone CandidateActive = "update: active"

reportMilestone :: Milestone -> IO ()
reportMilestone milestone = putStrLn (renderMilestone milestone) >> hFlush stdout

candidateFailureLine :: String
candidateFailureLine = "update: failed"

reportCandidateFailure :: IO ()
reportCandidateFailure = putStrLn candidateFailureLine >> hFlush stdout

updateMode :: [String] -> IO Bool
updateMode args = case args of
 ["--update-coordinate",name,dataDirectory,configDirectory] -> do
  version <- either fail pure (parseVersion name)
  reportMilestone CoordinatorListening
  command <- getLine `catch` \(_::IOException) -> pure ""
  let intent = StartStaged {stagedVersion=version, stagedRoots=UpdateRoots {dataRoot=dataDirectory, configRoot=configDirectory}}
  when (command == renderCoordinatorMessage Handoff) $ report (coordinate intent)
  pure True
 ["--update-recover"] -> report (coordinate RecoverOrLaunch) >> pure True
 _ -> pure False
 where
 report action = tryUpdate action >>= either (\problem -> showUpdateError (displayException problem) >> exitFailure) pure

data Dispatch = Running | Launch Version | Recover

discard :: [FilePath] -> IO ()
discard paths = forM_ paths $ \path ->
 (pathPresent path >>= flip when (removePathForcibly path)) `catch` \(_::IOException) -> pure ()

coordinate :: CoordinatorIntent -> IO ()
coordinate intent = do
 (root,owner) <- installed
 dispatch <- bracket (acquire root) releaseLease $ \lease -> do
  state <- readUpdateState root
  case (state,intent) of
   (Pending pending,_) -> do
    unless (owner == current (original pending)) (fail "Recovery must run through retained original version")
    restoreSnapshot root pending (writeUpdateState root (Settled (original pending)))
    discard [versionPath root (target pending), backupPath root (attempt pending)]
    pure (Launch (current (original pending)))
   (Settled selected,RecoverOrLaunch) -> pure (Launch (current selected))
   (Settled selected,StartStaged {stagedVersion=next, stagedRoots=directories}) -> do
    unless (owner == current selected && newTarget selected next) (fail "Update selection changed")
    nonce <- freshAttemptId
    let backup = backupPath root nonce
        discardUnpublished = do
         decision <- tryUpdate (readUpdateState root)
         case decision of
          Right (Settled unchanged) | unchanged == selected -> discard [versionPath root next,backup]
          _ -> pure ()
    result <- tryUpdate $ flip onException discardUnpublished $ do
     originalData <- canonicalizePath (dataRoot directories)
     originalConfig <- canonicalizePath (configRoot directories)
     let originalRoots = UpdateRoots {dataRoot=originalData, configRoot=originalConfig}
     validateRoots root originalRoots
     claimConfigRoot originalConfig
     let backups = root </> "backups"
     exists <- pathPresent backups
     unless exists (createDirectory backups)
     validatePath (versionExecutable root next)
     withRootIdentity originalData $ \dataId -> withRootIdentity originalConfig $ \configId -> do
      saved <- withRootLocks originalData $ do
       fingerprint <- snapshot backup originalRoots
       reserveDataRoot originalData (DataReservation root nonce)
       let pending = PendingUpdate
            { original=selected, target=next, attempt=nonce, roots=originalRoots
            , dataIdentity=dataId, configIdentity=configId, backupDigest=fingerprint }
       writeUpdateState root (Pending pending)
       pure pending
      downgradeLease lease
      runCandidate root saved
    case result of
     Right () -> do
      forM_ (previous selected) $ \old ->
       discard [versionPath root (previousVersion old),backupPath root (previousBackup old)]
      pure Running
     Left problem -> do
      decision <- readUpdateState root
      hPutStrLn stderr ("Sapiens update: " ++ displayException problem) `catch` \(_::IOException) -> pure ()
      either throwIO pure (afterCandidateFailure next problem decision)
 case dispatch of
  Running -> pure ()
  Launch version -> launchVersion root version []
  Recover -> coordinate RecoverOrLaunch
 where
 acquire root = case intent of
  StartStaged {} -> acquireLease (leasePath root) True
  RecoverOrLaunch -> acquireLease (leasePath root) True `catch` \(problem::IOException) ->
   fail ("Recovery is deferred until Sapiens releases the installation lease. Close Sapiens and relaunch from its installed shortcut. " ++ displayException problem)

afterCandidateFailure :: Version -> SomeException -> UpdateState -> Either SomeException Dispatch
afterCandidateFailure next problem state = case state of
 Settled selection
  | current selection == next -> Left (toException (userError committedError))
  | otherwise -> Right (Launch (current selection))
 Pending _ | Just (_::CandidateNotJoined) <- fromException problem -> Left problem
 Pending _ -> Right Recover
 where
 committedError = "The update was committed, but activation failed. Quit Sapiens, then open it from the installed shortcut to start the selected version. " ++ displayException problem

commitSelection :: PendingUpdate -> UpdateState -> Maybe Selection
commitSelection expected observed = do
 guard (observed == Pending expected)
 let retained = Previous (current (original expected)) (attempt expected) (backupDigest expected)
 pure (Selection (target expected) (Just retained))

runCandidate :: FilePath -> PendingUpdate -> IO ()
runCandidate root pending = mask $ \restore -> withCandidate (versionExecutable root (target pending)) []
 [("SAPIENS_UPDATE_ATTEMPT",attemptName (attempt pending)),("SAPIENS_DATA_DIR",dataRoot (roots pending)),("SAPIENS_CONFIG_DIR",configRoot (roots pending))] $ \candidate -> do
  (do
   restore (await (60 * 60) candidate CandidateReady)
   alive <- candidateAlive candidate
   unless alive (fail "Candidate exited before commit")
   state <- readUpdateState root
   selection <- maybe (fail "Update decision changed before Ready") pure (commitSelection pending state)
   writeUpdateState root (Settled selection)
   candidateOwnership candidate True)
   `onException` (tryUpdate (candidateOwnership candidate False) >>= either (throwIO . CandidateNotJoined) pure)
  restore $ do
   sendCandidate candidate (renderCoordinatorMessage Commit)
   await 60 candidate CandidateActive

await :: Int -> Candidate -> Milestone -> IO ()
await seconds candidate milestone =
 timeout (seconds * 1000000) loop >>= maybe (fail ("Timed out waiting for " ++ expected)) pure
 where
 expected = renderMilestone milestone
 loop = do
  message <- candidateMessage candidate
  when (message == candidateFailureLine) (fail ("Candidate failed before " ++ expected))
  unless (message == expected) loop

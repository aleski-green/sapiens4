module YokeReplay (catchUpMain) where

import qualified Append4.KV as K
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (genericLength)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Migrations
import Network.HTTP.Client
import qualified Network.HTTP.Types as H
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import Config (identityFileVersion, yokeStart)
import Environment (EnvironmentId(..))
import Types (at, failure, num, obj, readJSON, str, writeJSON)
import Yoke (ReplayStep(..), cursorKey, planApply, replayStep)
import YokeWire (CatchUp(..), HistoryPage(..), Writer(..), decodePage, decodeWriter, encodeCatchUp)

catchUpMain :: Text -> FilePath -> IO ExitCode
catchUpMain from directory = do
 root <- makeAbsolute directory
 manager <- newManager defaultManagerSettings
 Writer corpora source <- fetch decodeWriter manager (from <> "/api/corpora")
 adoptCorpora root corpora
 result <- bracket (Migrations.openCorpora root) K.closeStore (\store -> catchUp manager from store source yokeStart)
 BL.putStrLn (encodeCatchUp result)
 pure ExitSuccess

adoptCorpora :: FilePath -> Text -> IO ()
adoptCorpora root corpora = do
 createDirectoryIfMissing True root
 let identityPath = root </> "corpora-identity.json"
 exists <- doesFileExist identityPath
 if exists then do
  saved <- readJSON identityPath (obj [])
  unless (at saved "corpora_id" == corpora) (failure (H.statusCode H.conflict409) "This data folder belongs to another corpora")
 else writeJSON identityPath (obj [("version",num identityFileVersion),("corpora_id",str corpora)])

fetch :: (BL.ByteString -> Either String a) -> Manager -> Text -> IO a
fetch decoder manager url = do
 request <- parseUrlThrow (T.unpack url)
 response <- httpLbs request { requestHeaders = [("X-Sapiens-Local", "1")] } manager
 either (failure (H.statusCode H.badGateway502) . T.pack) pure (decoder (responseBody response))

catchUp :: Manager -> Text -> K.Store -> EnvironmentId -> Integer -> IO CatchUp
catchUp manager from store source applied = do
 after <- K.getValue store (cursorKey source) >>= maybe (pure yokeStart) K.integerValue
 page <- fetch decodePage manager (from <> "/api/yoke/history?after=" <> T.pack (show after))
 unless (pageEnvironment page == source) (failure (H.statusCode H.conflict409) "The writer changed while catching up")
 if null (pageAppends page) then pure (CatchUp source applied after) else do
  mapM_ (apply store source) (pageAppends page)
  catchUp manager from store source (applied + genericLength (pageAppends page))

apply :: K.Store -> EnvironmentId -> K.Append -> IO ()
apply store source item = do
 outcome <- K.submit store (planApply source item) >>= K.await
 case replayStep outcome of
  Replayed -> pure ()
  ReplayRejected rejected -> failure (H.statusCode H.conflict409) (T.pack ("Replay stopped: " <> show rejected))

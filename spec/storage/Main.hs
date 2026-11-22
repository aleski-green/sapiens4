module Main where

import Control.Exception
import Control.Concurrent
import System.Timeout (timeout)
import qualified Data.Text as T
import Control.Monad
import Data.Aeson
import qualified Data.Aeson.KeyMap as M
import qualified Data.Aeson.Key as K
import Data.IORef
import Data.Maybe
import Data.Text (Text)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import System.Directory
import System.FilePath
import System.Environment
import System.IO (hFlush,stdout,hGetLine)
import System.Process
import qualified Data.ByteString.Lazy as L
import qualified Database.SQLite.Simple as SQL
import qualified KV

assertThat :: String -> Bool -> IO ()
assertThat label condition = unless condition (fail label)
withStore :: (FilePath -> KV.Database -> IO ()) -> IO ()
withStore use = do
 root <- getTemporaryDirectory
 identity <- UUID.toString <$> UUID.nextRandom
 let path=root </> ("sapiens-kv-test-"++identity)
 bracket_ (createDirectory path) (removePathForcibly path) $ bracket (KV.open path) KV.close (use path)
value :: Text -> Value
value role=object ["role" .= role]
main :: IO ()
main = getArgs >>= \args -> case args of
 ["--legacy-fixture",root] -> legacyFixture root
 ["--crash-phase",root,phase] -> crashChild root phase
 [] -> checks
 _ -> fail "Usage: sapiens-storage-check [--legacy-fixture ROOT]"
checks :: IO ()
checks = do
 withStore $ \_ db -> do
  KV.putRecord db "sapis/s1" (value "assistant")
  KV.pulse db (pure ())
  KV.putRecord db "sapis/s1" (value "tentative")
  observed <- KV.readSnapshot db (KV.getRecord db "sapis/s1")
  assertThat "read snapshot exposed tentative state" (observed==Just (value "assistant"))
  KV.putRecord db "sapis/s1" (value "assistant")
  first <- KV.submit db $ KV.putRecord db "sapis/s1" (value "manager") >> KV.putRecord db "sapis/s1" (value "supervisor")
  second <- KV.submit db $ KV.putRecord db "sapis/s1" (value "manager")
  prior <- KV.getRecord db "sapis/s1"
  assertThat "queued data became visible before Pulse" (prior==Just (value "assistant"))
  KV.pulse db (pure ())
  KV.await first >> KV.await second
  facts <- KV.history db "sapis/s1/role"
  assertThat "netting persisted intermediate values" (length facts==2)
  noChange <- KV.submit db $ KV.putRecord db "sapis/s1" (value "assistant") >> KV.putRecord db "sapis/s1" (value "manager")
  KV.pulse db (pure ()) >> KV.await noChange
  assertThat "net-zero transaction appended a field fact" . (==2) . length =<< KV.history db "sapis/s1/role"
  rejected <- KV.submit db $ KV.putRecord db "sapis/s1" (value "invalid") >> fail "reject whole batch"
  KV.pulse db (pure ())
  result <- try (KV.await rejected) :: IO (Either SomeException ())
  assertThat "invalid transaction was not rejected" (either (const True) (const False) result)
  assertThat "invalid transaction leaked a partial write" . (==Just (value "manager")) =<< KV.getRecord db "sapis/s1"
  fired <- newIORef Nothing
  action <- KV.submit db $ do
   KV.putRecord db "routine/r1" (object ["prompt" .= ("Vienna"::Text)])
   captured <- KV.getRecord db "routine/r1"
   KV.afterCommit db "invoke-1" (fromMaybe Null captured) (writeIORef fired captured)
   KV.putRecord db "routine/r1" (object ["prompt" .= ("Dubai"::Text)])
  assertThat "effect ran before commit" . isNothing =<< readIORef fired
  KV.pulse db (pure ()) >> KV.await action
  assertThat "effect read final state instead of its captured input" . (==Just (object ["prompt" .= ("Vienna"::Text)])) =<< readIORef fired
  old <- KV.atPulse db 1 "sapis/s1/role"
  assertThat "historical read changed" (old==Just (object ["type" .= ("primitive"::Text),"data" .= ("assistant"::Text)]))
  membershipPulse <- KV.currentPulse db
  KV.deleteRecord db "routine/r1"
  KV.pulse db (pure ())
  assertThat "historical membership was lost" . (==["routine/r1"]) =<< KV.members db (Just membershipPulse) "routine/"
  assertThat "current membership contains a deleted record" . null =<< KV.members db Nothing "routine/"
  assertThat "historical search lost deleted data" . (not . null) =<< KV.searchText db True "Dubai"
  assertThat "current search returned a deleted value" . null =<< KV.searchText db False "Dubai"
 withStore $ \_ db -> do
  one <- KV.submit db $ KV.withActorContext db "first" $
   KV.putRecord db "sapis/s1" (object ["role" .= ("manager"::Text),"name" .= ("Alice"::Text)])
  two <- KV.submit db $ KV.withActorContext db "second" $
   KV.putRecord db "sapis/s1" (object ["role" .= ("manager"::Text),"name" .= ("Bob"::Text)])
  KV.pulse db (pure ()) >> KV.await one >> KV.await two
  role <- KV.history db "sapis/s1/role"
  name <- KV.history db "sapis/s1/name"
  let actor (Object row)=case M.lookup "source" row of Just (Object source) -> M.lookup "actor" source; _ -> Nothing
      actor _=Nothing
  assertThat "field attribution was overwritten by another field's writer" (map actor role==[Just (String "first")] && map actor name==[Just (String "second")])
 withStore $ \path db -> do
  KV.putRecord db "optional/value" Null
  KV.putRecord db "messages/m1" (object ["text" .= ("Durable"::Text),"order" .= (1::Int)])
  KV.pulse db (pure ())
  number <- KV.currentPulse db
  KV.close db
  bracket (KV.open path) KV.close $ \reopened -> do
   assertThat "JSON null was confused with a deleted record" . (==Just Null) =<< KV.getRecord reopened "optional/value"
   assertThat "reopen lost committed records" . isJust =<< KV.getRecord reopened "messages/m1"
   KV.pulse reopened (pure ())
   assertThat "Pulse identity was reused after restart" . (>number) =<< KV.currentPulse reopened
 withStore $ \path db -> do
  KV.putRecord db "sapis/s1" (value "saved")
  KV.pulse db (pure ())
  fired <- newIORef False
  bad <- KV.submit db $ do
   KV.putRecord db "sapis/s1" (object ["too-long" .= object [K.fromText (T.replicate 510 "x") .= Null]])
   KV.afterCommit db "must-not-launch" Null (writeIORef fired True)
  failed <- try (KV.pulse db (pure ())) :: IO (Either SomeException ())
  rejected <- try (KV.await bad) :: IO (Either SomeException ())
  assertThat "failed commit was acknowledged" (either (const True) (const False) failed && either (const True) (const False) rejected)
  assertThat "failed commit launched an effect" . not =<< readIORef fired
  assertThat "failed commit leaked state" . (==Just (value "saved")) =<< KV.getRecord db "sapis/s1"
  pending <- KV.submit db (KV.putRecord db "sapis/s1" (value "unsaved"))
  KV.close db
  cancelled <- try (KV.await pending) :: IO (Either SomeException ())
  assertThat "shutdown left a pending caller hanging" (either (const True) (const False) cancelled)
  bracket (KV.open path) KV.close $ \reopened ->
   assertThat "uncommitted data survived restart" . (==Just (value "saved")) =<< KV.getRecord reopened "sapis/s1"
 withStore $ \_ first -> withStore $ \_ second -> do
  a <- newEmptyMVar
  b <- newEmptyMVar
  KV.start first (myThreadId >>= void . tryPutMVar a)
  KV.start second (myThreadId >>= void . tryPutMVar b)
  threads <- timeout 3000000 ((,) <$> takeMVar a <*> takeMVar b)
  assertThat "local roots do not share one Pulse worker" (maybe False (uncurry (==)) threads)
 forM_ ["before","after"] crashBoundary
 putStrLn "PASS: atomic batches, netting, deferred effects, history, deletion, search and restart"

-- A real v00.01.00 root, with an interrupted call and non-domain workspace data.
legacyFixture :: FilePath -> IO ()
legacyFixture root = do
 createDirectoryIfMissing True (root </> "agentpy/agents/sapi_saved")
 createDirectoryIfMissing True (root </> "workspaces/sapi_saved")
 let save name value=L.writeFile (root </> name) (encode value)
 save "corpora-identity.json" (object ["version" .= (1::Int),"corpora_id" .= ("b8815591-97e9-405f-9d9c-5767216dfcab"::Text)])
 save "corpora-settings.json" (object ["device" .= ("This computer"::Text),"scope" .= ("Saved scope"::Text),"status" .= ("paused"::Text),"revision" .= (1::Int)])
 save "agentpy/agents/sapi_saved/state.json" (object
  ["schema_version" .= (2::Int),"agid" .= ("sapi_saved"::Text),"revision" .= (4::Int),"event_sequence" .= (0::Int)
  ,"last_output" .= Null,"chat" .= ([]::[Value]),"events" .= ([]::[Value])
  ,"turns" .= [object ["id" .= ("saved-review"::Text),"flow" .= ("chat"::Text),"input" .= ("Review the proposal"::Text)
    ,"status" .= ("budget_blocked"::Text),"created" .= ("2026-10-27T12:00:00+00:00"::Text)]]])
 writeFile (root </> "workspaces/sapi_saved/Notes.md") "Preserve this private note"
 bracket (SQL.open (root </> "corpora.sqlite3")) SQL.close $ \db -> do
  SQL.execute_ db "CREATE TABLE agents (id TEXT PRIMARY KEY, name TEXT, role TEXT, color TEXT, face TEXT, created TEXT)"
  SQL.execute_ db "INSERT INTO agents VALUES ('sapi_saved','Saved chief','Head of Corpora','#123456','🧠','2026-10-27T12:00:00+00:00')"
  SQL.execute_ db "CREATE TABLE preferences (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
  SQL.execute_ db "INSERT INTO preferences VALUES (1,'{\"browser_version\":1,\"panel\":\"chat\",\"workspaces\":{}}')"
  SQL.execute_ db "CREATE TABLE system_pulse (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
  SQL.execute_ db "INSERT INTO system_pulse VALUES (1,'{\"bpm60\":200,\"bph60\":7}')"

-- Kill a separate writer process on either side of its durable commit boundary.
-- No graceful close runs in that process.
crashChild :: FilePath -> String -> IO ()
crashChild root phase = do
 db <- KV.open root
 KV.putRecord db "objects/new" (object ["text" .= ("Crash boundary"::Text)])
 KV.afterCommit db "crash-action" (object ["input" .= ("Captured"::Text)]) (pure ())
 when (phase=="after") (KV.pulse db (pure ()))
 putStrLn "ready"
 hFlush stdout
 forever (threadDelay 1000000)

crashBoundary :: String -> IO ()
crashBoundary phase = withStore $ \root db -> do
 KV.putRecord db "objects/saved" (value "stable")
 KV.pulse db (pure ())
 old <- KV.currentPulse db
 KV.close db
 executable <- getExecutablePath
 bracket (createProcess (proc executable ["--crash-phase",root,phase]) {std_out=CreatePipe})
  (\(_,_,_,child) -> terminateProcess child >> void (waitForProcess child)) $ \(_,output,_,child) -> do
   line <- timeout 10000000 (maybe (fail "Missing child pipe") hGetLine output)
   assertThat "crash writer did not reach its barrier" (line==Just "ready")
   terminateProcess child
   void (waitForProcess child)
 bracket (KV.open root) KV.close $ \reopened -> do
  object <- KV.getRecord reopened "objects/new"
  intent <- KV.getRecord reopened "intents/crash-action"
  membership <- KV.members reopened Nothing "objects/"
  indexed <- KV.searchText reopened False "Crash boundary"
  number <- KV.currentPulse reopened
  let committed=phase=="after"
  assertThat "crash tore records, intents or indexes"
   (isJust object==committed && isJust intent==committed && ("objects/new" `elem` membership)==committed && not (null indexed)==committed)
  assertThat "crash corrupted the Pulse sequence" (number==old + if committed then 1 else 0)
  KV.pulse reopened (pure ())
  assertThat "crash restart reused a Pulse" . (>number) =<< KV.currentPulse reopened

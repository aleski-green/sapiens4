-- v00.01.00 -> v00.02.00. This script owns the entire data transition.
-- It runs offline, under the updater's verified backup and exclusive root locks.
module V00_02_00 (migrate) where

import Crypto.Hash.SHA256 (hash)
import Data.ByteArray.Encoding (convertToBase, Base(Base16))
import Control.Exception
import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as L
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.List (sortOn)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import System.Directory
import System.FilePath
import Types hiding (database)
import LegacyState
import RuntimePaths (containedPath)
import qualified Memo
import Network.URI (escapeURIString, isUnreserved)
import qualified KV

migrate :: FilePath -> FilePath -> IO ()
migrate root _config = do
 forM_ ["corpora.sqlite3","remote-receipts.sqlite3","agentpy","workspaces","state.lmdb",".migration-v00.02.00"] $ \name -> void (containedPath root (root </> name))
 sourceExists <- doesFileExist (root </> "corpora.sqlite3")
 unless sourceExists (fail "Legacy SQLite store is missing; restore the complete data root")
 let stage=root </> ".migration-v00.02.00"
     destination=root </> "state.lmdb"
 present <- doesPathExist destination
 when present $ fail "LMDB destination already exists without a completed build migration; restore the update backup."
 staged <- doesPathExist stage
 when staged (removePathForcibly stage)
 createDirectory stage
 copyLegacy root stage "corpora.sqlite3"
 bracket (KV.open stage) KV.close $ \target -> do
  let put=KV.putRecord target
  bracket (open (stage </> "corpora.sqlite3")) close $ \source -> do
   execute_ source "PRAGMA query_only=ON"
   integrity <- query_ source "PRAGMA quick_check" :: IO [Only Text]
   unless (integrity==[Only "ok"]) (fail "Legacy database integrity check failed")
   tables <- map fromOnly <$> (query_ source "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name" :: IO [Only Text])
   forM_ tables $ \table -> do
    unless (T.all (\c -> c `elem` (['a'..'z']++['_'])) table) (fail "Invalid legacy table name")
    columns <- map fromOnly <$> (query source "SELECT name FROM pragma_table_info(?) ORDER BY cid" (Only table) :: IO [Only Text])
    rows <- query_ source (fromString ("SELECT * FROM "++T.unpack table)) :: IO [[SQLData]]
    forM_ (zip [0::Int ..] rows) $ \(ordinal,fields) -> do
     let row=obj (zip columns (map sqlValue fields))
         ident=identifier (get row "id" `fallback` get row "sequence" `fallback` get row "job" `fallback` num ordinal)
     -- Preserve all original rows, including retired flows and historical tables.
     put ("legacy/"<>table<>"/"<>T.pack (show ordinal)) row
     case table of
      "agents" -> put ("agents/"<>ident) row
      "turns" -> put ("turns/"<>ident) row
      "jobs" -> when (at row "flow" `elem` ["chat","computer"]) (put ("turns/"<>ident) row)
      "message_inputs" -> put ("message_inputs/"<>ident) (putJSON "attachments" row)
      "activity_events" -> put ("activity_events/"<>ident) (putJSON "details" row)
      "attachments" -> decodeColumn row >>= \v -> put ("attachments/"<>at v "id") v
      "group_attachments" -> decodeColumn row >>= \v -> put ("attachments/"<>at v "id") v
      "system_pulse" -> pure () -- Legacy counters remain in legacy/, never run again.
      _ | table `elem` ["workloads","groups","scheduled_routines","pulse_calls","turn_details","preferences"] -> do
       value <- decodeColumn row
       let key=if table=="scheduled_routines" then at value "id" else ident
       put (table<>"/"<>key) value
      _ -> pure ()
  receiptsExist <- doesFileExist (root </> "remote-receipts.sqlite3")
  when receiptsExist $ do
   copyLegacy root stage "remote-receipts.sqlite3"
   bracket (open (stage </> "remote-receipts.sqlite3")) close $ \source -> do
    execute_ source "PRAGMA query_only=ON"
    saved <- query_ source "SELECT room,id,hash,reply,created FROM receipts" :: IO [(Text,Text,Text,Maybe Text,Double)]
    forM_ saved $ \(room,ident,digest,reply,created) -> do
     let key=TE.decodeUtf8 (convertToBase Base16 (hash (TE.encodeUtf8 (room<>"/"<>ident))))
     put ("remote-receipts/"<>key) (obj [("room",str room),("id",str ident),("hash",str digest),("legacy_reply",maybe Null str reply),("created",toJSON created)])
  roster <- KV.records target "agents/"
  when (null roster) (fail "Legacy data have no agents")
  forM_ roster $ \(_,profile) -> do
   let ident=at profile "id"; folder=root </> "agentpy/agents" </> T.unpack ident
   unless (safeIdentifier ident) (fail "Invalid legacy agent identity")
   void (containedPath root folder)
   void (containedPath folder (folder </> "state.json"))
   original <- readJSON (folder </> "state.json") Null
   put ("legacy-agent-state/"<>ident) original
   state <- if int (get original "schema_version")==3 then decodeValue 500 original
            else validated (migrateAgentState (int (get original "schema_version")) original)
   unless (at (stateJSON state) "agid"==ident) (fail "Mismatched legacy agent identity")
   put ("states/"<>ident) (remove ["schema_version","initial_manager"] (stateJSON (mapTurns recoverTurn state)))
   settings <- readJSON (folder </> "host.json") empty
   put ("agent-settings/"<>ident) settings
   migrateMemo (root </> "workspaces" </> T.unpack ident) profile
  forM_ [("corpora-settings.json","corpora-settings/1"),("model-settings.json","model-settings/1"),("agentpy/corpora/directory.json","directory/1")] $ \(path,key) -> do
   exists <- doesFileExist (root </> path)
   when exists $ readJSON (root </> path) Null >>= put key
  existingDirectory <- fromMaybe empty <$> KV.getRecord target "directory/1"
  let ordered=sortOn (\(_,v) -> (at v "created",at v "id")) roster
      chief=at (snd (head ordered)) "id"
  entries <- forM ordered $ \(_,profile) -> do
   let ident=at profile "id"; entry=get existingDirectory ident
   old <- fromMaybe empty <$> KV.getRecord target ("legacy-agent-state/"<>ident)
   let parent=if ident==chief then Null else get entry "parent" `fallback` get old "initial_manager" `fallback` str chief
   pure (ident,merge (obj [("scope",str "")]) (Types.put "parent" parent entry))
  put "directory/1" (obj entries)
  importArchives target (root </> "agentpy/corpora/archive") ""
  normalizeRoutines target
  normalizePreferences root target
  put "migration/v00.02.00" (obj [("from",str "v00.01.00"),("to",str "v00.02.00"),("agents",num (length roster))])
  KV.pulse target (pure ())
  imported <- KV.records target "agents/"
  unless (imported==roster) (fail "Migration roster verification failed")
 -- Reopen and validate durable data before publishing the new store.
 bracket (KV.open stage) KV.close $ \db -> do
  states <- KV.records db "states/"
  forM_ states $ \(_,value) -> void (decodeValue 500 value :: IO AgentState)
 renameDirectory (stage </> "state.lmdb") destination
 removePathForcibly stage
 where
 safeIdentifier t=not (T.null t) && T.all (\c -> c `elem` (['a'..'z']++['A'..'Z']++['0'..'9']++"_-")) t
 identifier (String t)=t
 identifier v=jsonText v
 sqlValue SQLNull=Null
 sqlValue (SQLText t)=str t
 sqlValue (SQLInteger n)=toJSON n
 sqlValue (SQLFloat n)=toJSON n
 sqlValue (SQLBlob b)=obj [("bytes_base64",str (TE.decodeUtf8 (Base64.encode b)))]
 decodeColumn row=either fail pure (eitherDecodeStrict' (TE.encodeUtf8 (at row "value")))
 putJSON key row=put key (parseJSONText (at row key)) row

importArchives :: KV.Database -> FilePath -> Text -> IO ()
importArchives db folder prefix = do
 exists <- doesDirectoryExist folder
 when exists $ listDirectory folder >>= mapM_ (\name -> do
  let path=folder </> name; key=prefix<>T.pack name
  symlink <- pathIsSymbolicLink path
  when symlink (fail "Archive symlinks are not supported during migration")
  directory <- doesDirectoryExist path
  if directory then importArchives db path (key<>"/") else when (takeExtension name==".json") $ do
   value <- readJSON path Null
   KV.putRecord db ("archives/"<>T.dropEnd 5 key) value)

normalizeRoutines :: KV.Database -> IO ()
normalizeRoutines db = do
 routines <- KV.records db "scheduled_routines/"
 works <- map snd <$> KV.records db "workloads/"
 groups <- map snd <$> KV.records db "groups/"
 forM_ routines $ \(key,r) -> unless (has r "runCount") $ do
  let count=case findId (at r "owner") groups of
       Just group -> length [t | t<-items group "tasks",get t "routine"==get r "id"]
       Nothing -> length [w | w<-works,get (get w "origin") "routine"==get r "id"]
  KV.putRecord db key (merge r (obj [("runCount",num count),("paused",Bool (count>=1000))]))

normalizePreferences :: FilePath -> KV.Database -> IO ()
normalizePreferences root db = do
 prefs <- fromMaybe empty <$> KV.getRecord db "preferences/1"
 workspaces <- forM (pairs (get prefs "workspaces")) $ \(owner,workspace) -> do
  tabs <- forM (items workspace "tabs") $ \tab ->
   if get prefs "browser_version"==num 1 then pure tab else do
    converted <- if not (T.null (at tab "artifact")) then pure (put "path" (str (T.pack (root </> "workspaces" </> T.unpack owner </> "artifacts" </> T.unpack (at tab "artifact")))) tab) else
     if at tab "type"=="html" then do
      identity <- newId
      let path=root </> "workspaces" </> T.unpack owner </> ("saved-tab-"++T.unpack identity++".html")
      writeText path (at tab "html")
      pure (put "path" (str (T.pack path)) tab)
     else pure tab
    identity <- newId
    let url=if not (T.null (at converted "path")) then "file://"<>T.pack (escapeURIString (\c -> isUnreserved c || c `elem` ("/:"::String)) (T.unpack (at converted "path"))) else at converted "url" `fallbackText` "about:blank"
    pure (merge (remove ["type","artifact","html"] converted) (obj [("url",str url),("zoom",num 1),("command",obj [("seq",str identity),("action",str "navigate")])]))
  pure (owner,merge workspace (obj [("tabs",arr tabs),("bookmarks",get workspace "bookmarks" `fallback` arr [])]))
 let panel=at prefs "panel"; updated=if panel=="mindmap" then put "panel" (str "notes") prefs else if panel `elem` ["cron","log"] then put "panel" (str "chat") prefs else prefs
 KV.putRecord db "preferences/1" (merge (remove ["work_views"] updated) (obj [("workspaces",obj workspaces),("browser_version",num 1)]))
 where fallbackText a b=if T.null a then b else a

-- Legacy workspace conversion belongs to this build script, never startup.
migrateMemo :: FilePath -> Value -> IO ()
migrateMemo root profile = do
 exists <- doesPathExist (root </> "Notes.html")
 unless exists $ do
  sources <- filterM doesPathExist [root </> "Notes.yaml",root </> "Notes.md"]
  forM_ (listToMaybe sources) $ \source -> do
   Memo.validate root source
   old <- readText source
   let content=if takeExtension source==".md" then "notes: "<>jsonText (str old) else old
   writeText (root </> "Notes.html") (Memo.migratedMemo (at profile "name") (at profile "role") content)

-- SQLite may checkpoint on close even when all statements are reads. Read a
-- private copy (including any WAL) so legacy input bytes remain untouched.
copyLegacy :: FilePath -> FilePath -> FilePath -> IO ()
copyLegacy root stage name = forM_ [name,name<>"-wal"] $ \entry -> do
 source <- containedPath root (root </> entry)
 exists <- doesFileExist source
 when exists (copyFile source (stage </> entry))

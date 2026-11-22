{-# LANGUAGE OverloadedStrings #-}
module Store where

import Control.Exception
import Control.Concurrent.MVar
import Control.Monad
import Data.Aeson hiding (pairs)
import Data.List (nub,find,sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.List.NonEmpty as NE
import Types
import qualified KV

data Collection = Workloads | Groups | ScheduledRoutines | PulseCalls | TurnDetails | Preferences deriving (Eq, Show)
tableName :: Collection -> Text
tableName table = case table of
 Workloads -> "workloads"
 Groups -> "groups"
 ScheduledRoutines -> "scheduled_routines"
 PulseCalls -> "pulse_calls"
 TurnDetails -> "turn_details"
 Preferences -> "preferences"
openDatabase :: FilePath -> IO KV.Database
openDatabase = KV.open
closeDatabase :: Service -> IO ()
closeDatabase s = modifyMVar_ (serviceDatabase s) $ \db -> mapM_ KV.close db >> pure Nothing
closeConnection :: KV.Database -> IO ()
closeConnection = KV.close
collection :: Service -> Text -> IO [Value]
collection s name = database s >>= \db -> map snd <$> KV.records db (name<>"/")
values :: Service -> Collection -> IO [Value]
values s = collection s . tableName
recentPulses :: Service -> IO [Value]
recentPulses s = take 500 . reverse . sortOn (\v -> (int (get v "num"),at v "id")) <$> values s PulseCalls
putValue :: Service -> Collection -> Text -> Value -> IO ()
putValue s table i = writeDomain s (tableName table<>"/"<>i)
singleton :: Service -> Collection -> IO Value
singleton s table = readDomain s (tableName table<>"/1") empty
saveSingleton :: Service -> Collection -> Value -> IO ()
saveSingleton s table = writeDomain s (tableName table<>"/1")
initialize :: Service -> IO ()
initialize _ = pure ()
agents :: Service -> IO [Value]
agents s = sortOn (\v -> (at v "created",at v "id")) <$> collection s "agents"
agentProfiles :: Service -> IO [AgentProfile]
agentProfiles s = agents s >>= traverse (decodeValue 500)
agent :: Service -> Text -> IO Value
agent s i = readDomain s ("agents/"<>i) Null >>= \v -> if v==Null then failure 404 "Unknown Sapi" else pure v
mainAgent :: Service -> IO Text
mainAgent s = agentIdText . populationChief <$> (population s >>= maybe (failure 500 "CORPORA has no Chief Sapi") pure)
population :: Service -> IO (Maybe Population)
population s = fmap populationRoster . NE.nonEmpty . map profileId <$> agentProfiles s
addAgent :: Service -> Value -> IO ()
addAgent s v = writeDomain s ("agents/"<>at v "id") v
updateAgent :: Service -> Text -> Value -> IO ()
updateAgent s i fields = agent s i >>= addAgent s . (`merge` fields)
attachments :: Service -> Text -> IO [Value]
attachments s a = filter ((==a) . (`at` "agent")) <$> collection s "attachments"
saveAttachment :: Service -> Value -> IO ()
saveAttachment s v = writeDomain s ("attachments/"<>at v "id") v
pendingVoices :: Service -> IO [Value]
pendingVoices s = take 1 . filter (\v -> at v "kind"=="voice" && at v "transcript_status"=="pending" && not (boolean (get v "cancelled"))) <$> collection s "attachments"
updateAttachment :: Service -> Value -> IO ()
updateAttachment = saveAttachment
message :: Service -> Text -> Text -> [Value] -> IO ()
message s i t as = do
 old <- readDomain s ("message_inputs/"<>i) Null
 when (old==Null) $ writeDomain s ("message_inputs/"<>i) (obj [("job",str i),("text",str t),("attachments",arr as)])
record :: Service -> [Text] -> Text -> Text -> Value -> Text -> Maybe Text -> IO ()
record s owners entity event details suppliedActor suppliedAgency = do
 (source,kind) <- currentActor s
 let actor=if suppliedActor=="admin" then source else suppliedActor
     agency=if isJust suppliedAgency then suppliedAgency else kind
 time <- now
 forM_ (nub (owners ++ [actor | "sapi_" `T.isPrefixOf` actor])) $ \owner -> do
  i <- newId
  writeDomain s ("activity_events/"<>i) (obj [("id",str i),("owner",str owner),("timestamp",str time),("actor",str actor),("entity",str entity),("event",str event),("agency",maybe Null str agency),("details",details)])
events :: Service -> IO Value
events s = do
 rows <- reverse . sortOn (\v -> (at v "timestamp",at v "id")) <$> collection s "activity_events"
 pure $ obj [(k,arr (take 100 vs)) | (k,vs)<-M.toList (M.fromListWith (flip (++)) [(at v "owner",[remove ["owner"] v]) | v<-rows])]
data TurnProjection = TurnProjection
 { projectionStatus :: TurnStatus, projectionOrigin :: Value, projectionOwners :: [Text]
 , projectionActor :: Text, projectionOutput :: Maybe Value }

projectTurn :: Text -> AgentState -> Turn -> TurnProjection
projectTurn owner state turn = TurnProjection status origin owners actor output
 where
 status=if turnStatus turn==Done && turnField turn "warning"/=Null then Warning else turnStatus turn
 origin=turnField turn "origin" `fallback` empty
 owners=owner:[at origin "group" | has origin "group"]
 actor=if status==Queued then if has origin "routine" then "system" else text (get origin "author" `fallback` str "admin") else owner
 output=listToMaybe [get m "content" | m<-items (stateJSON state) "chat",get m "turn"==toJSON (turnId turn),at m "role"=="agent"]

project :: Service -> Text -> IO ()
project s a = void (projectArchives s a)
projectArchives :: Service -> Text -> IO [Turn]
projectArchives s a = do
 state <- agentState s a
 fmap catMaybes $ forM (agentTurns state) $ \typed -> do
  let turn=toJSON typed; i=at turn "id"; projection=projectTurn a state typed
      status=wireName (projectionStatus projection); origin=projectionOrigin projection
      output=projectionOutput projection
      archiveNeeded=isNothing output && status `elem` ["done","warning"] && batchLeader typed==turnId typed
  previous <- readDomain s ("turns/"<>i) empty
  when (get previous "status"/=str status) $ record s (projectionOwners projection) i ("call."<>status)
   (obj [("previous",get previous "status"),("origin",origin),("error",get turn "error"),("warning",get turn "warning")]) (projectionActor projection) (Just (if has turn "output_order" then "chatOutput" else at turn "agency_kind"))
  putValue s TurnDetails i (selectPresent ["origin","batch_id","batch_members","agency_kind","slot","pulseId","output_at","output_order"] turn)
  archived <- if archiveNeeded then readArchive s a ("runs/"<>i) else pure empty
  let nextOutput=fromMaybe (get archived "output") output
  writeDomain s ("turns/"<>i) (obj [("id",str i),("agent",str a),("flow",get turn "flow"),("input",get turn "input"),("status",str status),("output",nextOutput `fallback` get previous "output"),("error",get turn "error" `fallback` get turn "warning"),("created",get turn "created")])
  pure (if archiveNeeded then Just typed else Nothing)
turns :: Service -> IO [Value]
turns s = do
 rows <- sortOn (\v -> (at v "created",at v "id")) <$> collection s "turns"
 forM rows $ \v -> do
  msg <- readDomain s ("message_inputs/"<>at v "id") empty
  details <- readDomain s ("turn_details/"<>at v "id") empty
  pure (merge (merge v details) (obj [("attachments",get msg "attachments" `fallback` arr []),("input",get msg "text" `fallback` get v "input")]))
saveRoutine :: Service -> Value -> IO Value
saveRoutine s v = do
 i <- if has v "id" then pure (at v "id") else ("routine_sch_"<>) <$> newId
 let value=put "id" (str i) v
 putValue s ScheduledRoutines i value
 pure value
pulseCall :: Service -> Pulse -> Text -> Text -> Int -> [Text] -> IO ()
pulseCall s tick a kind slot groups = do
 t <- now
 i <- newId
 let v=merge (toJSON tick) (obj [("id",str i),("agent",str a),("agencyKind",str kind),("slot",num slot),("timestamp",str t)])
 putValue s PulseCalls i v
 record s (a:groups) a "pulse.dispatched" v "system" (Just kind)
-- A sent attachment is marked "sent" and leaves the composer drafts on the host itself,
-- so a device that is a few seconds behind can never put it back.
forgetDrafts :: Service -> Text -> [Value] -> IO ()
forgetDrafts _ _ [] = pure ()
forgetDrafts s owner rows = do
 forM_ rows $ \row -> updateAttachment s (put "sent" (Bool True) row)
 dropDrafts s owner rows

-- | Take these attachments out of the owner's composer drafts (sent or cancelled ones).
dropDrafts :: Service -> Text -> [Value] -> IO ()
dropDrafts _ _ [] = pure ()
dropDrafts s owner rows = do
 prefs <- singleton s Preferences
 let drafts = get prefs "attachment_drafts"
     ids = map (`get` "id") rows
 when (has drafts owner) $ saveSingleton s Preferences (put "attachment_drafts" (put owner (arr (filter (`notElem` ids) (list (get drafts owner)))) drafts) prefs)

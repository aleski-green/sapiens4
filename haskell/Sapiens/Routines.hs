{-# LANGUAGE OverloadedStrings #-}
module Sapiens.Routines where

import Control.Monad
import qualified Command as C
import Data.Aeson hiding (pairs)
import Data.List (find)
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import qualified Data.UUID as UUID
import qualified Data.UUID.V5 as UUID5
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import Sapiens.Types
import qualified Sapiens.Store as DB
import Sapiens.Population
import qualified Sapiens.Delegation as D

initializeRoutines :: Service -> IO ()
initializeRoutines s = do
 routines <- DB.values s "scheduled_routines"
 works <- DB.values s "workloads"
 groups <- DB.values s "groups"
 forM_ routines $ \r -> unless (has r "runCount") $ do
  let group=findId (at r "owner") groups
      count=case group of Just g->length [t | t<-items g "tasks",get t "routine"==get r "id"]; Nothing->length [w | w<-works,get (get w "origin") "routine"==get r "id"]
  void (DB.saveRoutine s (merge r (obj [("runCount",num count),("paused",Bool (count>=1000))])))
save :: Service -> Text -> Value -> Value -> Maybe Text -> Maybe Int -> Maybe Text -> IO Value
save s owner minutes execution identity previous source = do
 body <- textField (obj [("prompt",execution)]) "prompt" 16000
 let interval=int minutes
 require (minutes == num interval && interval>=1 && interval<=525600 && body `notElem` ["PROMPT","TODO"]) 400 "Choose 1–525600 minutes and replace PROMPT with the work to execute"
 if "group_" `T.isPrefixOf` owner then do
  groups <- DB.values s "groups"
  g <- maybe (failure 404 "Unknown Group") pure (findId owner groups)
  require (not (boolean (get g "archived"))) 409 "Restore this Group before changing its work"
 else requireActive s owner
 routines <- filter ((==owner) . (`at` "owner")) <$> DB.values s "scheduled_routines"
 let existing = identity >>= (`findId` routines)
 when (isJust identity) $ require (isJust existing) 404 "Unknown Scheduled Routine in this conversation"
 case (existing,previous) of
  (Just r,Just old) -> require (int (get r "minutes")==old) 409 "Frequency changed; open Edit again for the current routine"
  _ -> pure ()
 let prior = if isNothing identity && isJust source then find (\r -> get r "sourceCall" == maybe Null str source && get r "minutes" == minutes && at r "prompt" == body) routines else Nothing
 case prior of
  Just r -> pure r
  Nothing -> do
   t <- getCurrentTime
   let initial = fromMaybe (obj ([("created",str (timestamp t)),("runCount",num 0),("paused",Bool False)]++[("sourceCall",str c) | c <- maybeToList source])) existing
       value=merge initial (obj [("owner",str owner),("title",str (T.unwords (take 7 (T.words body)))),("minutes",minutes),("prompt",str body),("updated",str (timestamp t)),("nextDue",str (timestamp (addUTCTime (fromIntegral (60*interval)) t)))])
   r <- DB.saveRoutine s value
   DB.record s [owner] (at r "id") (if isJust identity then "routine.updated" else "routine.created") r "admin" Nothing
   pure r
setPaused :: Service -> Text -> Text -> Bool -> IO Value
setPaused s owner identity paused = do
 routines <- DB.values s "scheduled_routines"
 r <- maybe (failure 404 "Unknown Scheduled Routine in this conversation") pure (find (\r -> at r "owner"==owner && at r "id"==identity) routines)
 if boolean (get r "paused")==paused then pure r else do
  t <- getCurrentTime
  let fields=[("paused",Bool paused),("updated",str (timestamp t))] ++ [("nextDue",str (timestamp (addUTCTime (fromIntegral (60*int (get r "minutes"))) t))) | not paused] ++ [("runCount",num 0) | not paused && int (get r "runCount")>=1000]
  result <- DB.saveRoutine s (merge r (obj fields))
  DB.record s [owner] identity (if paused then "routine.paused" else "routine.resumed") result "admin" Nothing
  pure result
command :: Service -> Text -> Text -> Bool -> IO (Maybe Value)
command s owner input attached = case C.interpret attached (T.unpack input) of
 Left error -> failure 400 (T.pack error)
 Right Nothing -> pure Nothing
 Right (Just c) -> Just <$> case c of
  C.Create interval body -> save s owner (toJSON interval) (str (T.pack body)) Nothing Nothing Nothing
  C.Edit i old interval body -> save s owner (toJSON interval) (str (T.pack body)) (Just (T.pack i)) (Just (fromIntegral old)) Nothing
  C.SetPaused i paused -> setPaused s owner (T.pack i) paused
receipt :: Value -> Text -> Text
receipt r input = action <> " @"<>at r "id"<>" ( "<>at r "title"<>" )\nStatus: "<>status<>" · "<>jsonText (get r "runCount")<>"/1000 runs\nFrequency: every "<>jsonText (get r "minutes")<>" minutes\nExecute: "<>at r "prompt"
 where action=fromMaybe "Updated" (listToMaybe (T.words input) >>= (`lookup` [("Pause","Paused"),("Resume","Resumed"),("Add","Created")]))
       status=if boolean (get r "paused") then "Paused" else "Planned"
acknowledge :: Service -> Text -> Text -> Value -> IO Value
acknowledge s owner input r = do
 i <- newId
 t <- now
 let output=receipt r input
     turn=obj [("id",str i),("flow",str "chat"),("input",str input),("status",str "done"),("created",str t),("output_at",str t)]
     messages=[obj [("role",str role),("content",str content),("turn",str i),("time",str t)] | (role,content)<-[("user",input),("agent",output)]]
 modifyState s owner $ \state -> merge state (obj [("turns",arr (items state "turns"++[turn])),("chat",arr (items state "chat"++messages))])
 DB.project s owner
 pure (obj [("id",str i),("agent",str owner),("status",str "done"),("flow",str "chat")])
dispatch :: Service -> Value -> IO ()
dispatch s tick = when (at tick "frequency" == "bph60") $ do
 t <- getCurrentTime
 routines <- DB.values s "scheduled_routines"
 forM_ routines $ \r -> unless (boolean (get r "paused")) $ do
  let owner=at r "owner"; count=int (get r "runCount")
  if count>=1000 then do
   void (DB.saveRoutine s (put "paused" (Bool True) r))
   DB.record s [owner] (at r "id") "routine.paused" (obj [("reason",str "run limit"),("runCount",num count)]) "system" Nothing
  else case parseTime (at r "nextDue") of
   Just due | due<=t -> do
    groups <- DB.values s "groups"
    let group=findId owner groups; a=maybe owner (`at` "lead") group
    inactive <- retired s a
    unless (inactive || maybe False (boolean . (`get` "archived")) group) $ do
     let identity=T.filter (/='-') (UUID.toText (UUID5.generateNamed UUID5.namespaceURL (BS.unpack (TE.encodeUtf8 (at r "id"<>":"<>at r "nextDue")))))
         origin=obj [("routine",get r "id"),("routineOwner",str owner),("title",get r "title"),("minutes",get r "minutes"),("taskType",str "automated"),("executionPrompt",get r "prompt")]
         turn=obj [("id",str identity),("flow",str "chat"),("input",get r "prompt"),("status",str "queued"),("created",str (timestamp t)),("attempt",num 1),("origin",origin),("batchable",Bool True)]
     case group of
      Nothing -> do
       projected <- DB.turns s
       when (isNothing (findId identity projected)) $ do
        modifyState s a $ \state -> merge state (obj [("turns",arr (items state "turns"++[turn])),("chat",arr (items state "chat"++[obj [("role",str "user"),("content",get r "prompt"),("turn",str identity),("time",str (timestamp t)),("origin",origin)]]))])
        DB.project s a
       D.begin s a turn
       (w,c) <- D.getWork s identity
       when (at c "state"=="Running" && null (items w "decisions")) $ D.saveWork s (D.withCall w (put "state" (str "Queued") c))
      Just g -> when (isNothing (findId identity (items g "requests"))) $ do
       let taskId="gtask_"<>identity; groupOrigin=merge origin (obj [("group",str owner),("author",str "admin")])
           message=obj [("id",str identity),("author",str "admin"),("text",get r "prompt"),("created",str (timestamp t)),("routine",get r "id")]
           task=obj [("id",str taskId),("title",get r "title"),("body",get r "prompt"),("assignee",str a),("state",str "in_progress"),("deleted",Bool False),("revision",num 1),("created",str (timestamp t)),("author",str "admin"),("updated_by",str "admin"),("history",arr []),("results",arr []),("taskType",str "automated"),("routine",get r "id")]
           request=obj [("id",str identity),("message",str identity),("target",str a),("root",str identity),("created",str (timestamp t)),("status",str "queued"),("settled",Bool False),("task",str taskId),("task_revision",num 1),("origin",groupOrigin)]
       DB.putValue s "groups" owner (merge g (obj [("messages",arr (items g "messages"++[message])),("tasks",arr (items g "tasks"++[task])),("requests",arr (items g "requests"++[request])),("revision",num (int (get g "revision")+1)),("updated",str (timestamp t))]))
     let interval=fromIntegral (60*int (get r "minutes")); jumps=floor (diffUTCTime t due / interval)+1 :: Integer; next=timestamp (addUTCTime (interval*fromIntegral jumps) due)
     void $ DB.saveRoutine s (merge r (obj [("nextDue",str next),("runCount",num (count+1)),("paused",Bool (count+1>=1000))]))
     DB.record s [owner] (at r "id") "routine.triggered" (obj [("turn",str identity),("runCount",num (count+1)),("nextDue",str next)]) "system" Nothing
     when (count+1>=1000) $ DB.record s [owner] (at r "id") "routine.paused" (obj [("reason",str "run limit"),("runCount",num (count+1))]) "system" Nothing
   _ -> pure ()

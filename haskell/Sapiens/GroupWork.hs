{-# LANGUAGE OverloadedStrings #-}
module Sapiens.GroupWork where

import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe, isNothing, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Sapiens.Types
import qualified Sapiens.Store as DB
import Sapiens.GroupModel

data GroupTask = GroupTask
 { taskId :: Text, taskTitle :: Text, taskBody :: Text, taskAssignee :: AgentId
 , taskState :: TaskState, taskDeleted :: Bool, taskRevision :: Int, taskFields :: Object
 } deriving (Eq, Show)
instance FromJSON GroupTask where
 parseJSON = withObject "Group task" $ \o -> GroupTask <$> o .: "id" <*> o .: "title" <*> o .: "body" <*> o .: "assignee" <*> o .: "state" <*> o .: "deleted" <*> o .: "revision" <*> pure (foldr KM.delete o ["id","title","body","assignee","state","deleted","revision"])
instance ToJSON GroupTask where
 toJSON task = mergeFields [("id",str (taskId task)),("title",str (taskTitle task)),("body",str (taskBody task)),("assignee",toJSON (taskAssignee task)),("state",toJSON (taskState task)),("deleted",Bool (taskDeleted task)),("revision",num (taskRevision task))] (Object (taskFields task))

data TaskPatch = TaskPatch { patchTitle :: Maybe Text, patchBody :: Maybe Text, patchAssignee :: Maybe AgentId, patchState :: Maybe TaskState, patchDeleted :: Maybe Bool, patchRevision :: Maybe Int } deriving (Eq, Show)
instance FromJSON TaskPatch where
 parseJSON value = do
  onlyFields ["title","body","assignee","state","deleted","revision"] value
  let optional key parser = if has value key then Just <$> parser (get value key) else pure Nothing
  title <- optional "title" $ \raw -> textFieldP "title" 500 value >> parseJSON raw
  body <- optional "body" $ \raw -> do
   text <- parseJSON raw
   unless (T.length text <= 16000) (fail "Task body must be text, at most 16000 characters")
   pure text
  TaskPatch title body <$> optional "assignee" parseJSON <*> optional "state" parseJSON <*> optional "deleted" parseJSON <*> optional "revision" parseJSON

findTask :: Value -> Text -> IO Value
findTask group tid = maybe (failure 404 "Unknown Group task") pure (findId tid (items group "tasks"))
readTask :: Value -> Text -> IO GroupTask
readTask group tid = findTask group tid >>= decodeValue 500
validateTask :: Value -> Value -> IO TaskPatch
validateTask group input = do
 patch <- decodeValue 400 input
 forM_ (patchAssignee patch) $ \owner -> require (toJSON owner `elem` items group "members") 400 "Assign tasks only to current Group members"
 pure patch
applyPatch :: TaskPatch -> GroupTask -> GroupTask
applyPatch patch task = task
 { taskTitle=fromMaybe (taskTitle task) (patchTitle patch), taskBody=fromMaybe (taskBody task) (patchBody patch)
 , taskAssignee=fromMaybe (taskAssignee task) (patchAssignee patch), taskState=fromMaybe (taskState task) (patchState patch)
 , taskDeleted=fromMaybe (taskDeleted task) (patchDeleted patch) }
createTask :: Service -> Text -> Value -> Text -> IO Value
createTask s gid input actor = do
 group <- getGroup s gid True
 authorizeGroup s group actor Member
 patch <- validateTask group input
 title <- maybe (failure 400 "title must be nonempty text, at most 500 characters") pure (patchTitle patch)
 owner <- maybe (field 500 group "lead") pure (patchAssignee patch)
 tid <- fresh "gtask_"; created <- now
 let task=GroupTask tid (T.strip title) (fromMaybe "" (patchBody patch)) owner Backlog False 1 (KM.fromList [("created",str created),("author",str actor),("updated_by",str actor),("history",arr []),("results",arr [])])
 void (saveGroup s (append "tasks" (toJSON task) group) actor "task created" (str tid))
 pure (toJSON task)
updateTask :: Service -> Text -> Text -> Value -> Text -> IO Value
updateTask s gid tid input actor = do
 group <- getGroup s gid True; authorizeGroup s group actor Member
 task <- readTask group tid; patch <- validateTask group input
 require (patchRevision patch == Just (taskRevision task)) 409 "Task changed; read its latest revision before editing"
 require (not (taskDeleted task) || patchDeleted patch == Just False) 409 "Restore this task before editing"
 require (patchDeleted patch /= Just False || toJSON (taskAssignee task) `elem` items group "members" || isJust (patchAssignee patch)) 409 "Choose a current member before restoring this task"
 updated <- now
 let reset=any (has input) ["title","body","assignee","deleted"] && isNothing (patchState patch)
     revised=applyPatch patch task
     metadata=mergeFields [("updated_by",str actor),("updated",str updated)] $ appendItems "history" [remove ["history","results"] (toJSON task)] (Object (taskFields task))
     changed=revised { taskState=if reset then Backlog else taskState revised, taskRevision=taskRevision task+1, taskFields=case metadata of Object o -> o; _ -> taskFields task }
 void (saveGroup s (replace "tasks" (toJSON changed) group) actor (if taskDeleted changed then "task deleted" else "task updated") (str tid))
 pure (toJSON changed)
startTask :: Service -> Text -> Text -> Value -> Text -> Text -> IO Value
startTask s gid tid revision actor root = do
 group <- getGroup s gid True; authorizeGroup s group actor Member
 task <- readTask group tid
 require (revision == toJSON (taskRevision task) && not (taskDeleted task)) 409 "Task changed or was deleted; refresh before starting"
 require (toJSON (taskAssignee task) `elem` items group "members") 409 "Assign this task to a current member first"
 require (not (any (\r -> at r "task" == tid && at r "status" `elem` ["queued","running"]) (items group "requests"))) 409 "This task already has a pending execution"
 let changed=task { taskState=InProgress, taskRevision=taskRevision task+1, taskFields=KM.insert "updated_by" (str actor) (taskFields task) }
 initial <- message actor (taskTitle task <> "\n\n" <> taskBody task)
 let entry=mergeFields ([("task",str tid)] ++ [("memo_pending",Bool True) | actor == "admin"]) initial
 request <- newRequest entry (agentIdText (taskAssignee task)) root
 let call=mergeFields [("task",str tid),("task_revision",num (taskRevision changed))] request
 void (saveGroup s (append "requests" call (append "messages" entry (replace "tasks" (toJSON changed) group))) actor "task started" (str tid))
 pure (toJSON changed)

newRequest :: Value -> Text -> Text -> IO Value
newRequest entry target root = do
 i <- newId; t <- now
 pure (toJSON (GroupRequest (RunId i) (AgentId target) Queued False (KM.fromList [("message",get entry "id"),("root",if T.null root then get entry "id" else str root),("created",str t)])))
settleTask :: Value -> Value -> Value -> IO (Value, Maybe Bool)
settleTask group request turn = if not (has request "task") then pure (group,Nothing) else do
 task <- findTask group (at request "task"); t <- now
 status <- field 500 turn "status"
 let stale = boolean (get task "deleted") || get task "revision" /= get request "task_revision"
     result = obj [("turn",get request "id"),("author",get request "target"),("text",get turn "output"),("error",get turn "error"),("revision",get request "task_revision"),("stale",Bool stale),("created",str t)]
     changed = append "results" result task
     finished = if stale then changed else merge changed (obj [("state",str (if completedStatus status then "done" else "backlog")),("revision",num (int (get task "revision")+1)),("updated_by",get request "target")])
 pure (replace "tasks" finished group,Just stale)
assignedTasks :: Service -> Text -> IO [Value]
assignedTasks s actor = do
 groups <- DB.values s DB.Groups
 pure [merge task (obj [("group",get g "id"),("group_name",get g "name"),("group_archived",get g "archived")]) | g <- groups,task <- items g "tasks",at task "assignee" == actor]
runTask :: Service -> Text -> Text -> Value -> Text -> IO Value
runTask s gid tid revision actor = startTask s gid tid revision actor ""

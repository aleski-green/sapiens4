{-# LANGUAGE OverloadedStrings #-}
module Sapiens.GroupWork where

import Control.Monad
import Data.Aeson hiding (pairs)
import Data.Text (Text)
import qualified Data.Text as T
import Sapiens.Types
import qualified Sapiens.Store as DB
import Sapiens.GroupModel

findTask group tid = maybe (failure 404 "Unknown Group task") pure (findId tid (items group "tasks"))
validateTask group input = do
 require (all (`elem` ["title","body","assignee","state","deleted","revision"]) (keys input)) 400 "Unknown task field"
 when (has input "title") $ void (textField input "title" 500)
 when (has input "body") $ require (case get input "body" of String body -> T.length body <= 16000; _ -> False) 400 "Task body must be text, at most 16000 characters"
 when (has input "assignee") $ require (get input "assignee" `elem` items group "members") 400 "Assign tasks only to current Group members"
 when (has input "state") $ require (at input "state" `elem` ["backlog","in_progress","done"]) 400 "Choose backlog, in_progress or done"
 when (has input "deleted") $ require (case get input "deleted" of Bool _ -> True; _ -> False) 400 "deleted must be a boolean"
createTask s gid input actor = do
 group <- getGroup s gid True; authorizeGroup s group actor "member"; validateTask group input
 title <- textField input "title" 500; tid <- fresh "gtask_"; created <- now
 let task = obj [("id",str tid),("title",str title),("body",get input "body" `fallback` str ""),("assignee",get input "assignee" `fallback` get group "lead"),("state",str "backlog"),("deleted",Bool False),("revision",num 1),("created",str created),("author",str actor),("updated_by",str actor),("history",arr []),("results",arr [])]
 void (saveGroup s (append "tasks" task group) actor "task created" (str tid))
 pure task
updateTask s gid tid input actor = do
 group <- getGroup s gid True; authorizeGroup s group actor "member"
 task <- findTask group tid; validateTask group input
 require (get input "revision" == get task "revision" && get input "revision" /= Null) 409 "Task changed; read its latest revision before editing"
 require (not (boolean (get task "deleted")) || get input "deleted" == Bool False) 409 "Restore this task before editing"
 require (get input "deleted" /= Bool False || get task "assignee" `elem` items group "members" || has input "assignee") 409 "Choose a current member before restoring this task"
 updated <- now
 let snapshot = remove ["history","results"] task
     reset = any (has input) ["title","body","assignee","deleted"] && not (has input "state")
     changed = merge (merge (append "history" snapshot task) (remove ["revision"] input)) (obj ([("revision",num (int (get task "revision")+1)),("updated_by",str actor),("updated",str updated)] ++ [("state",str "backlog") | reset]))
 void (saveGroup s (replace "tasks" changed group) actor (if boolean (get changed "deleted") then "task deleted" else "task updated") (str tid))
 pure changed
startTask s gid tid revision actor root = do
 group <- getGroup s gid True; authorizeGroup s group actor "member"
 task <- findTask group tid
 require (revision == get task "revision" && not (boolean (get task "deleted"))) 409 "Task changed or was deleted; refresh before starting"
 require (get task "assignee" `elem` items group "members") 409 "Assign this task to a current member first"
 require (not (any (\r -> at r "task" == tid && at r "status" `elem` ["queued","running"]) (items group "requests"))) 409 "This task already has a pending execution"
 let changed = merge task (obj [("state",str "in_progress"),("revision",num (int (get task "revision")+1)),("updated_by",str actor)])
 initial <- message actor (at task "title" <> "\n\n" <> at task "body")
 let entry = merge initial (obj ([("task",str tid)] ++ [("memo_pending",Bool True) | actor == "admin"]))
 request <- newRequest entry (at task "assignee") root
 let call = merge request (obj [("task",str tid),("task_revision",get changed "revision")])
 void (saveGroup s (append "requests" call (append "messages" entry (replace "tasks" changed group))) actor "task started" (str tid))
 pure changed
newRequest entry target root = do
 i <- newId; t <- now
 pure (obj [("id",str i),("message",get entry "id"),("target",str target),("status",str "queued"),("root",if T.null root then get entry "id" else str root),("created",str t),("settled",Bool False)])
settleTask group request turn = if not (has request "task") then pure (group,Nothing) else do
 task <- findTask group (at request "task"); t <- now
 let stale = boolean (get task "deleted") || get task "revision" /= get request "task_revision"
     result = obj [("turn",get request "id"),("author",get request "target"),("text",get turn "output"),("error",get turn "error"),("revision",get request "task_revision"),("stale",Bool stale),("created",str t)]
     changed = append "results" result task
     finished = if stale then changed else merge changed (obj [("state",str (if at turn "status" `elem` ["done","warning"] then "done" else "backlog")),("revision",num (int (get task "revision")+1)),("updated_by",get request "target")])
 pure (replace "tasks" finished group,Just stale)
assignedTasks s actor = do
 groups <- DB.values s "groups"
 pure [merge task (obj [("group",get g "id"),("group_name",get g "name"),("group_archived",get g "archived")]) | g <- groups,task <- items g "tasks",at task "assignee" == actor]
runTask s gid tid revision actor = startTask s gid tid revision actor ""

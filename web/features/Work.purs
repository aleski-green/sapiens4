module Sapiens.Work (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Aff (try)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Sapiens.Runtime
import Sapiens.Text as T

past :: String -> Boolean
past status = A.elem status ["Completed", "Unresolved", "Failed", "Interrupted", "Cancelled"]

taskLabel :: String -> String
taskLabel state = field state $ value {backlog:"Backlog", in_progress:"In progress", done:"Done"}

groupCallTasks :: Value -> Effect (Array Value)
groupCallTasks group = traverse (\r -> do
  let message_ = find (\m -> field "id" m == field "message" r) $ items "messages" group
      result = find (\m -> field "turn" m == field "id" r) $ items "messages" group
      title = if boolean (r .! "memo") then "Update group Memo" else string $ message_ .! "text" <||> value "Group call"
      states = value {queued:"Queued",running:"Running",output_pending:"Running",done:"Completed",warning:"Completed",failed:"Failed",interrupted:"Interrupted",cancelled:"Cancelled"}
  target <- exec "agent" [r .! "target"]
  pure $ value {id:r .! "id", title, state:states .! field "status" r <||> r .! "status", owner:r .! "target", sender:r .! "target", taskType:"call"
    , body:"objective: " <> stringify (value title) <> "\nassignee: " <> stringify (target .! "name") <> "\n", result:result .! "text", error:r .! "error"}) $
      A.reverse $ A.filter (not <<< boolean <<< flip get "task") $ items "requests" group

selectDefault :: Effect Unit
selectDefault = do
  selected <- exec "selected" []
  state <- read "state"
  live <- read "live"
  let group = field "kind" selected == "group"
  calls <- if group then groupCallTasks selected else pure $ A.filter (\w -> not (boolean $ w .! "origin" .! "group") && A.any (\id -> string id == field "selected" state) (items "participants" w)) $ items "workloads" live
  let states = map (field "state") calls <> (if group then map (\task -> if field "state" task == "done" then "Completed" else "Queued") (A.filter (not <<< boolean <<< flip get "deleted") $ items "tasks" selected) else [])
  write "taskPeriod" "upcoming"
  write "groupTaskFilter" "active"
  write "scheduledPeriod" "upcoming"
  if A.any (not <<< past) states then write "workView" "tasks"
  else if A.any (\r -> field "owner" r == field "selected" state && not (boolean $ r .! "paused")) (items "routines" live) then write "workView" "routine-scheduled"
  else if not (A.null states) then write "workView" "tasks" *> write "taskPeriod" "past" *> write "groupTaskFilter" "done"
  else write "workView" "memo"

rememberTask :: Value -> Effect Unit
rememberTask row = do
  previous <- map string <<< array <$> read "openGroupTasks"
  let id = field "openGroupTask" $ row .! "dataset"
  write "openGroupTasks" $ (if boolean (row .! "open") then [id] else []) <> A.filter (_ /= id) previous

taskCard :: Value -> Value -> Effect String
taskCard group task = do
  opened <- map string <<< array <$> read "openGroupTasks"
  assignee <- exec "agent" [task .! "assignee"]
  let running = A.any (\r -> field "task" r == field "id" task && A.elem (field "status" r) ["queued", "running"]) $ items "requests" group
  results <- traverse (\r -> do
    author <- exec "agent" [r .! "author"]
    text <- exec "formatText" [r .! "text" <||> r .! "error" <||> value "No reply saved."]
    pure $ "<div class=\"group-task-result\"><strong>" <> escape (field "name" author) <> (if boolean (r .! "stale") then " · Earlier revision" else "") <> "</strong><div>" <> string text <> "</div></div>") $ items "results" task
  history <- traverse (\h -> do
    person <- exec "agent" [h .! "assignee"]
    pure $ "<div class=\"group-task-result\"><strong>" <> escape (field "title" h) <> "</strong><p>" <> escape (field "name" person) <> " · " <> taskLabel (field "state" h) <> (if boolean (h .! "deleted") then " · Deleted" else "") <> "</p><p>" <> escape (field "body" h) <> "</p></div>") $ A.reverse $ items "history" task
  body <- if boolean (task .! "body") then exec "formatText" [task .! "body"] <#> \text -> "<div class=\"group-task-body\">" <> string text <> "</div>" else pure ""
  pure $ "<details class=\"task-row group-task\" data-open-group-task=\"" <> escape (field "id" task) <> "\" " <> (if A.elem (field "id" task) opened then "open" else "") <> "><summary class=\"task-summary\"><span class=\"task-row-copy\"><span class=\"task-title\">" <> escape (field "title" task) <>
    "</span><span class=\"task-meta\">" <> escape (field "name" assignee) <> " · " <> (if boolean (task .! "deleted") then "Deleted" else taskLabel (field "state" task)) <> "</span></span><span class=\"task-chevron\" aria-hidden=\"true\">›</span></summary><div class=\"task-content\">" <> body <>
    "<div class=\"actions\">" <> (if boolean (group .! "archived") then "" else "<button class=\"button\" data-group-task=\"" <> escape (field "id" task) <> "\" data-group=\"" <> escape (field "id" group) <> "\">" <> (if boolean (task .! "deleted") then "Restore / edit" else "Edit") <> "</button>" <>
      (if boolean (task .! "deleted") then "" else "<button class=\"button\" data-task-run=\"" <> escape (field "id" task) <> "\" data-group=\"" <> escape (field "id" group) <> "\" " <> (if running then "disabled" else "") <> ">" <> (if running then "Running / queued" else if field "state" task == "done" then "Run again" else "Run task") <> "</button>")) <>
    "</div>" <> (if A.null results then "" else "<details><summary>Results · " <> show (A.length results) <> "</summary>" <> join results <> "</details>") <>
    (if A.null history then "" else "<details><summary>Change history · " <> show (A.length history) <> "</summary>" <> join history <> "</details>") <> "</div></details>"

renderGroupTasks :: Value -> Value -> Effect Unit
renderGroupTasks host group = do
  qaIn host "[data-open-group-task]" >>= flip for_ rememberTask
  view <- string <$> read "workView"
  filter <- string <$> read "groupTaskFilter"
  let tasks = A.filter (\t -> (view /= "tasks-automated" || field "taskType" t == "automated") &&
        (if filter == "deleted" then boolean (t .! "deleted") else not (boolean $ t .! "deleted") && if filter == "done" then field "state" t == "done" else field "state" t /= "done")) $ items "tasks" group
  cards <- traverse (taskCard group) tasks
  html host $ "<section class=\"group-work\"><div class=\"group-task-list\">" <> join cards <> "</div></section>"
  list <- qIn host ".group-task-list"
  when (view /= "tasks-automated" && filter /= "deleted") do
    calls <- groupCallTasks group
    for_ calls \task -> when (past (field "state" task) == (filter == "done")) do
      row <- exec "taskRow" [task, group .! "id"]
      append list [row]
  when (A.null $ array $ list .! "children") $ html list "<p class=\"empty\">No tasks here yet.</p>"

renderScheduled :: Value -> Effect Unit
renderScheduled host = do
  state <- read "state"
  live <- read "live"
  period <- string <$> read "scheduledPeriod"
  let routines = A.filter (\r -> field "owner" r == field "selected" state) $ items "routines" live
      key = stringify $ value [state .! "selected", value period, value routines]
      planned = period == "upcoming"
  when (field "taskViewKey" (host .! "firstElementChild") /= key) do
    view <- element "section" "task-browser" ""
    setField view "taskViewKey" key
    list <- element "div" "task-list" ""
    attr list "aria-label" $ (if planned then "Planned" else "Paused") <> " scheduled routines"
    let rows = A.filter (\r -> boolean (r .! "paused") /= planned) routines
    if A.null rows then html list $ "<div class=\"task-empty\"><p>" <> (if planned then "No planned routines" else "No paused routines") <> "</p><small>" <> (if planned then "Create a scheduled routine through chat." else "Paused routines will appear here.") <> "</small></div>"
    else for_ rows \r -> do
      due <- construct (global .! "Date") [r .! "nextDue"] >>= \date_ -> call date_ "toLocaleString" []
      let paused = boolean $ r .! "paused"
          task = value {id:r .! "id", title:r .! "title", state:if paused then "Paused" else "Planned", owner:r .! "owner", sender:r .! "owner"
            , reference:"@" <> field "id" r, editRoutine:r .! "id", routineAction:if paused then "resume" else "pause", runCount:r .! "runCount" <||> value 0
            , meta:"Every " <> field "minutes" r <> " minutes" <> (if paused then "" else " · " <> string due)
            , body:"Frequency: every " <> field "minutes" r <> " minutes\nExecute: " <> field "prompt" r}
      exec "taskRow" [task,state .! "selected"] >>= \row -> append list [row]
    append view [list]
    replaceChildren host [view]

taskDialog :: Value -> Value -> Effect Unit
taskDialog group task = do
  options <- traverse (\id -> do
    a <- exec "agent" [id]
    pure $ "<option value=\"" <> escape (string id) <> "\" " <> (if same id (task .! "assignee" <||> group .! "lead") then "selected" else "") <> ">" <> escape (field "name" a) <> "</option>") $ items "members" group
  fire "modal" [value $ if boolean task then "Edit Group task" else "Create Group task", value $
    "<form id=\"group-task-form\" class=\"form-stack\"><label>Title<input name=\"title\" required maxlength=\"500\" value=\"" <> escape (field "title" task) <> "\"></label><label>Work to do<textarea name=\"body\" rows=\"5\" maxlength=\"16000\">" <> escape (field "body" task) <> "</textarea></label><label>Assignee<select name=\"assignee\">" <> join options <> "</select></label>" <>
    (if not (boolean task) then "" else "<label>Status<select name=\"state\">" <> join (map (\state -> "<option value=\"" <> state <> "\" " <> (if state == field "state" task then "selected" else "") <> ">" <> taskLabel state <> "</option>") ["backlog","in_progress","done"]) <> "</select></label>") <>
    "<button type=\"submit\" class=\"button primary\">" <> (if boolean (task .! "deleted") then "Restore task" else "Save task") <> "</button>" <>
    (if boolean task && not (boolean $ task .! "deleted") then "<button type=\"button\" class=\"button\" id=\"delete-group-task\">Delete task</button>" else "") <>
    "<p class=\"form-hint\">Saving keeps this as shared work. Use Run task to call the assignee. Deletions can be restored.</p></form>", value "GROUP WORK"]
  form <- q "#group-task-form"
  let saveTask deleted = do
        button <- qIn form "[type=submit]"
        setField button "disabled" true
        report do
          result <- try do
            data_ <- liftEffect do
              pairs <- construct (global .! "FormData") [form]
              call (global .! "Object") "fromEntries" [pairs]
            when (boolean task) $ liftEffect do
              set data_ "revision" $ task .! "revision"
              setField data_ "deleted" deleted
              when (boolean $ task .! "deleted") $ setField data_ "state" "backlog"
            void $ request ("/api/groups/" <> field "id" group <> "/tasks" <> if boolean task then "/" <> field "id" task else "") (if boolean task then "PUT" else "POST") data_
            void $ await $ exec "refresh" []
            liftEffect $ fire "closeModal" [] *> fire "toast" [value $ if deleted then "Task deleted." else "Task saved."]
          liftEffect do
            setField button "disabled" false
            case result of
              Left error -> fire "toast" [value $ message error]
              Right _ -> pure unit
  on form "submit" false \event -> prevent event *> saveTask false
  deletion <- q "#delete-group-task"
  when (boolean deletion) $ on deletion "click" false $ const $ saveTask true

eventTimestamp :: String -> Effect String
eventTimestamp timestamp = do
  date_ <- construct (global .! "Date") [value timestamp]
  let pad width number_ = let text = string number_ in S.joinWith "" (A.replicate (max 0 $ width - CU.length text) "0") <> text
  day <- call date_ "getDate" []
  month <- call date_ "toLocaleString" [value "en-GB",value {month:"short"}]
  hour <- call date_ "getHours" []
  minute <- call date_ "getMinutes" []
  second <- call date_ "getSeconds" []
  millis <- call date_ "getMilliseconds" []
  pure $ pad 2 day <> " " <> string month <> " " <> pad 2 hour <> ":" <> pad 2 minute <> " " <> pad 2 second <> "s ." <> pad 3 millis

renderUpdates :: Value -> Effect Unit
renderUpdates host = do
  prop "#composer-area" "hidden" true
  toggle host "notes-view" false
  state <- read "state"
  live <- read "live"
  let events = A.take 100 $ array $ live .! "events" .! field "selected" state
      name id = case id of
        "admin" -> "Admin"
        "system" -> "System"
        "corpora" -> "Corpora"
        _ -> string $ (find (\a -> field "id" a == id) $ items "agents" state) .! "name" <||> value (if T.test "^routine_sch_" "" id then "@" <> id else id)
      key = stringify $ value [state .! "selected",value $ map (flip get "id") events,value $ map (\a -> [a .! "id",a .! "name"]) $ items "agents" state]
  log <- qIn host ".event-log"
  unless (field "events" (host .! "dataset") == key && boolean log) do
    opened <- if same (host .! "dataset" .! "eventOwner") (state .! "selected") then map (field "event" <<< flip get "dataset") <$> qaIn host "details[open]" else pure []
    setField (host .! "dataset") "events" key
    set (host .! "dataset") "eventOwner" $ state .! "selected"
    html host "<section class=\"event-log\"><div class=\"event-columns event-head\"><span>Timestamp</span><span>Actor</span><span>Entity</span><span>Event</span><span>Agency</span><span></span></div><div class=\"event-rows\"></div></section>"
    list <- qIn host ".event-rows"
    for_ events \event -> do
      row <- element "details" "task-row event-row" ""
      setField (row .! "dataset") "event" $ field "id" event
      timestamp <- eventTimestamp $ field "timestamp" event
      arrow <- exec "activityChevron" [value true]
      let values = [name $ field "actor" event,name $ field "entity" event,field "event" event,string $ event .! "agency" <||> value "—"]
      html row $ "<summary class=\"event-columns\"><time datetime=\"" <> escape (field "timestamp" event) <> "\" title=\"" <> escape (field "timestamp" event) <> "\">" <> escape timestamp <> "</time>" <>
        join (map (\text -> "<span title=\"" <> escape text <> "\">" <> escape text <> "</span>") values) <> "<span class=\"event-chevron\">" <> string arrow <> "</span></summary>"
      let details = do
            pre <- qIn row "pre"
            if boolean (row .! "open") && not (boolean pre) then element "pre" "" (pretty $ event .! "details") >>= \node -> append row [node]
            else when (not (boolean $ row .! "open") && boolean pre) $ void $ call pre "remove" []
      on row "toggle" false $ const details
      setField row "open" $ A.elem (field "id" event) opened
      details
      append list [row]
    when (A.null events) $ html list "<p class=\"empty\">No events yet.</p>"

renderWork :: Value -> Effect Unit
renderWork host = do
  prop "#composer-area" "hidden" true
  state <- read "state"
  selected <- exec "selected" []
  view <- string <$> read "workView"
  if field "panel" state == "updates" then renderUpdates host else do
    let key = field "selected" state <> ":" <> view
        group = field "kind" selected == "group"
    existing <- qIn host "#work-content"
    when (field "work" (host .! "dataset") /= key || not (boolean existing)) do
      setField (host .! "dataset") "work" key
      html host "<div id=\"work-content\"></div>"
    content <- qIn host "#work-content"
    toggle host "notes-view" $ view == "memo"
    if view == "memo" then if group && field "revision" (selected .! "notes") == "missing" then html content "<p class=\"empty\">No shared Memo yet.</p>" else fire "renderNotes" [content]
    else if view == "routine-scheduled" then renderScheduled content
    else if not (A.elem view ["tasks", "tasks-automated"]) then do
      title <- exec "activityLabel" [value view]
      html content $ "<p class=\"empty\">" <> string title <> " is not available yet.</p>"
    else if group then renderGroupTasks content selected else fire "renderTasks" [content]

main :: Effect Unit
main = do
  write "openGroupTasks" ([] :: Array String)
  register "groupCallTasks" \args -> value <$> groupCallTasks (at 0 args)
  register "selectDefaultWorkView" \_ -> selectDefault $> null
  register "groupTaskCard" \args -> value <$> taskCard (at 0 args) (at 1 args)
  register "renderGroupTasks" \args -> renderGroupTasks (at 0 args) (at 1 args) $> null
  register "taskDialog" \args -> taskDialog (at 0 args) (at 1 args) $> null
  register "eventTimestamp" \args -> value <$> eventTimestamp (string $ at 0 args)
  for_ [{name:"renderScheduledRoutines", action:renderScheduled},{name:"renderUpdates",action:renderUpdates},{name:"renderWork",action:renderWork}] \entry ->
    register entry.name \args -> entry.action (at 0 args) $> null
  register "mountWork" \_ -> mount $> null

mount :: Effect Unit
mount = do
  let document = global .! "document"
  on document "toggle" true \event -> do
    let target = event .! "target"
    when (boolean (target .! "dataset" .! "openGroupTask") && boolean (target .! "isConnected")) $ rememberTask target
  on document "click" false \event -> do
    button <- closest (event .! "target") "button"
    when (boolean button) do
      state <- read "state"
      live <- read "live"
      view <- string <$> read "workView"
      let d = button .! "dataset"
          routine id = find (\r -> field "id" r == id && field "owner" r == field "selected" state) $ items "routines" live
      if has "newTask" d then fire "workDraft" [value $ if view == "routine-scheduled" then "Add New Scheduled Routine:\nFrequency: every XXX minutes\nExecute: PROMPT" else "Add New Task: TODO",value $ if view == "routine-scheduled" then "XXX" else "TODO"]
      else if boolean (d .! "runRoutine") then when (boolean $ routine $ field "runRoutine" d) $ fire "workDraft" [value $ "@" <> field "runRoutine" d <> "\nRun it now."]
      else if boolean (d .! "editRoutine") then do
        let r = routine $ field "editRoutine" d
        when (boolean r) $ fire "workDraft" [value $ "Edit @" <> field "id" r <> " ( " <> field "title" r <> " )\nEdit Frequency (prev every " <> field "minutes" r <> " minutes): new every XXX minutes\nEdit Execution Prompt as: " <> field "prompt" r,value "XXX"]
      else if boolean (d .! "pauseRoutine") || boolean (d .! "resumeRoutine") then do
        let id = string $ d .! "pauseRoutine" <||> d .! "resumeRoutine"
        when (boolean $ routine id) $ fire "workDraft" [value $ (if boolean (d .! "pauseRoutine") then "Pause Schedule Riutine" else "Resume Scheduled Routine") <> "\n@" <> id]
      else if boolean (d .! "workFilter") then do
        fire "closeActivityMenus" []
        selected <- exec "selected" []
        write (if view == "routine-scheduled" then "scheduledPeriod" else if field "kind" selected == "group" then "groupTaskFilter" else "taskPeriod") $ d .! "workFilter"
        fire "renderConversation" []
      else if boolean (d .! "groupTask") then do
        group <- exec "agent" [d .! "group"]
        taskDialog group $ find (\task -> field "id" task == field "groupTask" d) $ items "tasks" group
      else when (boolean (d .! "groupArchive") || boolean (d .! "taskRun") || boolean (d .! "groupCall")) do
        setField button "disabled" true
        report do
          outcome <- try do
            when (boolean $ d .! "groupArchive") do
              group <- liftEffect $ exec "agent" [d .! "groupArchive"]
              void $ request ("/api/groups/" <> field "id" group) "PUT" $ value {revision:group .! "revision", archived:not $ boolean $ group .! "archived"}
              liftEffect $ fire "closeModal" []
            when (boolean $ d .! "taskRun") do
              group <- liftEffect $ exec "agent" [d .! "group"]
              let task = find (\t -> field "id" t == field "taskRun" d) $ items "tasks" group
              void $ request ("/api/groups/" <> field "id" group <> "/tasks/" <> field "id" task <> "/run") "POST" $ value {revision:task .! "revision"}
            when (boolean $ d .! "groupCall") $ void $ request ("/api/groups/" <> field "group" d <> "/calls/" <> field "call" d <> "/" <> field "groupCall" d) "POST" $ value {}
            void $ await $ exec "refresh" []
            liftEffect $ fire "render" []
          liftEffect do
            setField button "disabled" false
            case outcome of
              Left error -> fire "toast" [value $ message error]
              Right _ -> pure unit

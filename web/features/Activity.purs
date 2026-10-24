module Sapiens.Activity (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Traversable (traverse)
import Effect (Effect)
import Sapiens.Runtime

navigation :: Array Value
navigation = array $ parse """[{"id":"memo","label":"Memo"},{"id":"tasks","label":"Tasks","children":[{"id":"tasks-call","label":"Call"},{"id":"tasks-backlog","label":"Backlog"},{"id":"tasks-automated","label":"Automated"}]},{"id":"automation","label":"Automation","children":[{"id":"routine","label":"Routines","children":[{"id":"routine-scheduled","label":"Scheduled"},{"id":"routine-callback","label":"Callbacks"},{"id":"routine-job","label":"Jobs"}]},{"id":"workflows","label":"Workflows","children":[{"id":"workflow-agentic","label":"Agentic"},{"id":"workflow-pipeline","label":"Pipelines"},{"id":"workflow-composer","label":"Composers"}]},{"id":"composer","label":"Composers","children":[{"id":"composer-workflow","label":"Workflow"},{"id":"composer-routine","label":"Routine"},{"id":"composer-call","label":"Call"}]}]}]"""

pathFor :: String -> Array Value
pathFor id = search [] navigation
  where
  search path nodes = fromMaybe [] $ A.head $ A.filter (not <<< A.null) $ map (\node ->
    let next = A.snoc path node
    in if field "id" node == id then next else search next $ items "children" node) nodes

label :: String -> String
label id = case id of
  "conversation" -> "Conversation"
  "pins" -> "Pins"
  "threads" -> "Threads"
  "comments" -> "Comments"
  "events" -> "Events"
  "records" -> "Records"
  _ -> field "label" $ fromMaybe null $ A.last $ pathFor id

chevron :: Boolean -> String
chevron sideways = "<svg class=\"activity-chevron" <> (if sideways then " sideways" else "") <> "\" viewBox=\"0 0 16 16\" width=\"12\" height=\"12\" fill=\"none\" aria-hidden=\"true\" focusable=\"false\"><path d=\"m4.5 6.25 3.5 3.5 3.5-3.5\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>"

closeMenus :: Effect Unit
closeMenus = do
  qa ".activity-menu" >>= flip for_ (\menu -> setField menu "hidden" true)
  qa "[data-activity-menu]" >>= flip for_ (\button -> attr button "aria-expanded" "false")

renderNavigation :: Effect Unit
renderNavigation = do
  state <- read "state"
  selected <- exec "selected" []
  workView <- string <$> read "workView"
  chatView <- string <$> read "chatView"
  updatesView <- string <$> read "updatesView"
  let panel = field "panel" state
      group = field "kind" selected == "group"
      view = if panel == "work" then workView else if panel == "updates" then updatesView else chatView
      item name owner = "<button data-activity-view=\"" <> name <> "\" data-activity-panel=\"" <> owner <> "\" class=\"" <> (if view == name then "selected" else "") <> "\" aria-pressed=\"" <> show (view == name) <> "\">" <> label name <> "</button>"
      workMenu = stringMap navigation \node ->
        if A.null (items "children" node) then item (field "id" node) "work" else
          let id = "activity-" <> field "id" node <> "-menu"
          in "<div class=\"activity-submenu-row\">" <> item (field "id" node) "work" <> "<button data-activity-menu=\"" <> id <> "\" aria-label=\"" <> field "label" node <> " menu\" aria-expanded=\"false\" aria-controls=\"" <> id <> "\">" <> chevron true <> "</button><div class=\"activity-menu activity-submenu\" id=\"" <> id <> "\" hidden>" <> stringMap (items "children" node) (\child -> item (field "id" child) "work") <> "</div></div>"
      menu owner = case owner of
        "work" -> workMenu
        "updates" -> item "events" "updates" <> "<button disabled title=\"Not active yet\">Records</button>"
        _ -> join (map (\v -> item v "chat") ["pins", "threads", "comments"]) <> "<hr><button data-activity-feedback>＋ Add feedback</button>"
      navHTML = join $ map (\owner ->
        let title = S.toUpper (CU.take 1 owner) <> CU.drop 1 owner
        in "<div class=\"activity-tab " <> (if panel == owner then "active" else "") <> "\"><button data-panel=\"" <> owner <> "\" aria-pressed=\"" <> show (panel == owner) <> "\">" <> title <>
          "</button><button class=\"activity-toggle\" data-activity-menu=\"activity-" <> owner <> "-menu\" aria-label=\"" <> title <> " menu\" aria-expanded=\"false\" aria-controls=\"activity-" <> owner <> "-menu\">" <> chevron false <>
          "</button><div class=\"activity-menu\" id=\"activity-" <> owner <> "-menu\" hidden>" <> menu owner <> "</div></div>") ["chat", "work", "updates"]
  nav <- q ".conversation-tabs"
  when (field "view" (nav .! "dataset") /= navHTML) $ html nav navHTML *> setField (nav .! "dataset") "view" navHTML
  previous <- q "#activity-viewbar"
  bar <- if boolean previous then pure previous else do
    node <- element "div" "" ""
    setField node "id" "activity-viewbar"
    void $ call nav "after" [node]
    pure node
  setField bar "hidden" $ panel == "updates" || panel == "work" && workView == "memo" || panel == "chat" && chatView == "conversation"
  let path = pathFor view
      caption nodes = S.joinWith " / " $ map (field "label") nodes
      detail = if panel /= "work" then "<span class=\"activity-view-title\">" <> label view <> "</span>"
        else if A.length path /= 3 then "<span class=\"activity-view-title\">" <> caption path <> "</span>"
        else let category = at 1 path
             in "<span class=\"activity-view-title\">" <> caption (A.take 2 path) <> " /</span><div class=\"activity-view-menu\"><button data-activity-menu=\"activity-category-menu\" aria-expanded=\"false\" aria-controls=\"activity-category-menu\" aria-label=\"" <> field "label" category <> " views\">" <> field "label" (at 2 path) <> " " <> chevron false <>
               "</button><div class=\"activity-menu\" id=\"activity-category-menu\" hidden>" <> stringMap (items "children" category) (\node -> item (field "id" node) "work") <> "</div></div>"
  tools <- if panel == "work" && A.elem workView ["tasks", "tasks-automated", "routine-scheduled"] then do
    let scheduled = workView == "routine-scheduled"
        groupTasks = group && not scheduled
        options = if scheduled then [{id:"upcoming", label:"Planned"}, {id:"paused", label:"Paused"}] else if groupTasks then [{id:"active", label:"Planned"}, {id:"done", label:"Executed"}, {id:"deleted", label:"Deleted"}] else [{id:"upcoming", label:"Planned"}, {id:"past", label:"Executed"}]
    filter <- string <$> read (if scheduled then "scheduledPeriod" else if groupTasks then "groupTaskFilter" else "taskPeriod")
    let selectedOption = fromMaybe {id:"", label:""} $ A.find (\o -> o.id == filter) options
    pure $ "<div class=\"work-nav-tools\"><div class=\"activity-view-menu\"><button data-activity-menu=\"activity-task-filter\" aria-expanded=\"false\" aria-controls=\"activity-task-filter\" aria-label=\"" <>
      (if scheduled then "Routine history" else if group then "Task status" else "Task history") <> "\">" <> selectedOption.label <> " " <> chevron false <>
      "</button><div class=\"activity-menu\" id=\"activity-task-filter\" hidden>" <> join (map (\option -> "<button data-work-filter=\"" <> option.id <> "\" class=\"" <> (if option.id == filter then "selected" else "") <> "\" aria-pressed=\"" <> show (option.id == filter) <> "\">" <> option.label <> "</button>") options) <>
      "</div></div>" <> (if boolean (selected .! "archived") then "" else "<button data-new-task>+ New</button>") <> "</div>"
    else pure ""
  let final = detail <> tools
  when (field "view" (bar .! "dataset") /= final) $ html bar final *> setField (bar .! "dataset") "view" final

draft :: String -> String -> Effect Unit
draft preset placeholder = do
  state <- read "state"
  setField state "panel" "chat"
  write "chatView" "conversation"
  fire "renderConversation" []
  input <- q "#message-input"
  let previous = field "value" input
      start = CU.length previous + if previous == "" then 0 else 2
      text = (if previous == "" then "" else previous <> "\n\n") <> preset
  setField input "value" text
  unless (boolean $ state .! "drafts") $ setField state "drafts" {}
  setField (state .! "drafts") (field "selected" state) text
  focus input
  index <- call (value preset) "indexOf" [value placeholder]
  let position = if placeholder == "" || int index < 0 then CU.length text else start + int index
      end = if placeholder == "" || int index < 0 then position else position + CU.length placeholder
  void $ call input "setSelectionRange" [value position,value end]
  fire "save" []

main :: Effect Unit
main = do
  for_ [{name:"scheduledPeriod", val:"upcoming"}, {name:"groupTaskFilter", val:"active"}, {name:"workView", val:"tasks"}, {name:"chatView", val:"conversation"}, {name:"updatesView", val:"events"}, {name:"taskPeriod", val:"upcoming"}] \entry -> write entry.name entry.val
  register "activityChevron" \args -> pure $ value $ chevron $ boolean $ at 0 args
  register "activityLabel" \args -> pure $ value $ label $ string $ at 0 args
  register "closeActivityMenus" \_ -> closeMenus $> null
  register "renderActivityNavigation" \_ -> renderNavigation $> null
  register "workDraft" \args -> draft (string $ at 0 args) (string $ at 1 args) $> null
  register "renderChatCollection" \args -> do
    state <- read "state"
    view <- string <$> read "chatView"
    let active = field "panel" state == "chat" && view /= "conversation"
    when active do
      toggle (at 0 args) "notes-view" false
      prop "#composer-area" "hidden" true
      html (at 0 args) $ "<p class=\"empty\">" <> label view <> " are not available yet.</p>"
    pure $ value active
  register "prepareActivityFeedback" \_ -> closeMenus *> draft "Feedback: " "" $> null
  register "mountActivity" \_ -> mount $> null

mount :: Effect Unit
mount = do
  let document = global .! "document"
  on document "click" false \event -> do
    button <- closest (event .! "target") "button"
    let d = button .! "dataset"
    if boolean (d .! "activityMenu") then do
      menu <- call document "getElementById" [d .! "activityMenu"]
      let opening = boolean $ menu .! "hidden"
      submenu <- call (menu .! "classList") "contains" [value "activity-submenu"]
      if not (boolean submenu) then closeMenus else do
        parent <- closest button ".activity-menu"
        qaIn parent "[data-activity-menu]" >>= flip for_ (\trigger -> unless (same trigger button) do
          node <- call document "getElementById" [trigger .! "dataset" .! "activityMenu"]
          setField node "hidden" true
          attr trigger "aria-expanded" "false")
      setField menu "hidden" $ not opening
      attr button "aria-expanded" $ show opening
    else if boolean (d .! "activityView") then do
      closeMenus
      state <- read "state"
      set state "panel" $ d .! "activityPanel"
      if field "panel" state == "work" then do
        let path = pathFor $ field "activityView" d
            node = fromMaybe null $ A.last path
        write "workView" $ if A.length path == 2 && boolean (node .! "children") then (at 0 $ items "children" node) .! "id" else d .! "activityView"
      else write (if field "panel" state == "chat" then "chatView" else "updatesView") $ d .! "activityView"
      fire "renderConversation" []
      fire "save" []
    else if has "activityFeedback" d then fire "prepareActivityFeedback" []
    else do
      inside <- closest (event .! "target") ".activity-menu"
      unless (boolean inside) closeMenus
  on document "keydown" false \event -> do
    let key = field "key" event
        target = event .! "target"
    trigger <- closest target "[data-activity-menu]"
    menu <- closest target ".activity-menu"
    if key == "Escape" then do
      open <- fromMaybe null <<< A.last <$> qa "[data-activity-menu][aria-expanded=\"true\"]"
      when (boolean open) $ prevent event *> closeMenus *> focus open
    else if boolean trigger && A.elem key ["ArrowDown", "ArrowRight"] then do
      prevent event
      expanded <- getAttr trigger "aria-expanded"
      when (expanded /= "true") $ void $ call trigger "click" []
      node <- call document "getElementById" [trigger .! "dataset" .! "activityMenu"]
      qIn node "button" >>= focus
    else when (boolean menu && A.elem key ["ArrowDown", "ArrowUp", "Home", "End"]) do
      prevent event
      candidates <- qaIn menu "button"
      parents <- traverse (flip closest ".activity-menu") candidates
      let buttons = A.mapMaybe identity $ A.zipWith (\button parent -> if same parent menu then Just button else Nothing) candidates parents
          index = fromMaybe (-1) $ A.findIndex (same target) buttons
          next = if key == "Home" then 0 else if key == "End" then A.length buttons - 1 else mod (index + if key == "ArrowDown" then 1 else A.length buttons - 1) (max 1 $ A.length buttons)
      focus $ at next buttons

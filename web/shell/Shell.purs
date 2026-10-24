module Sapiens.Shell (main, mount, initialState) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Traversable (traverse)
import Data.Foldable (for_)
import Data.String as S
import Data.String.CodeUnits as CU
import Effect (Effect)
import Sapiens.Runtime
import Sapiens.Text as T

initialState :: Value -> Value
initialState snapshot =
  let prefs = snapshot .! "preferences"
      agents = map (\a -> merge [a, value {kind:"sapi", scope:"personal", status:"online", autonomy:"assist", preview:"Ready for your message.", lastActivity:dateNumber $ field "created" a, unread:false}]) (items "agents" snapshot) <> items "groups" snapshot
      chosen = find (\a -> field "id" a == field "selected" prefs && not (boolean $ a .! "retired")) agents <||> at 0 agents
      selected = field "id" chosen
      workspaces = prefs .! "workspaces" <||> value {}
      ws = workspaces .! selected <||> value {tabs:[] :: Array Value}
      group = field "kind" chosen == "group"
  in value {agents, mainSapiId:(at 0 agents) .! "id", selected
    , scope:if group then value "groups" else prefs .! "scope" <||> value "all"
    , groupView:prefs .! "groupView" <||> if group then value selected else null
    , panel:if A.elem (field "panel" prefs) ["chat", "tasks", "notes", "work", "updates"] then field "panel" prefs else "chat"
    , mode:"assist", panes:merge [value {sidebar:true,chat:true,workspace:true}, prefs .! "panes"]
    , tabs:ws .! "tabs", activeTab:ws .! "activeTab" <||> (at 0 $ items "tabs" ws) .! "id", workspaces
    , drafts:prefs .! "drafts" <||> value {}, messages:value {}}

syncWorkspace :: Effect Unit
syncWorkspace = do
  state <- read "state"
  let owner = field "selected" state
      ws = state .! "workspaces" .! owner <||> value {tabs:[] :: Array Value}
      tabs = A.filter (\t -> field "url" t /= "about:blank" || boolean (t .! "path") || not (T.test "^(blank-|id-)" "" $ field "id" t)) $ items "tabs" ws
      active = if A.any (\t -> field "id" t == field "activeTab" ws) tabs then ws .! "activeTab" else (at 0 tabs) .! "id"
  write "workspaceOwner" owner
  setField state "tabs" tabs
  set state "activeTab" active

agent :: Value -> String -> Value
agent state id = find (\a -> field "id" a == id) (items "agents" state) <||> at 0 (items "agents" state)

avatar :: Value -> String -> Boolean -> Effect String
avatar a size presence = if field "kind" a == "group" then string <$> exec "groupAvatar" [a, value size]
  else pure $ "<span class=\"avatar " <> size <> "\" style=\"--avatar-color:" <>
    (if T.test "^#[a-f0-9]{6}$" "i" (field "color" a) then field "color" a else "#fdd997") <> "\" aria-hidden=\"true\">(" <> escape (field "face" a) <> ")" <>
    (if presence then "<i class=\"presence " <> (if A.elem (field "status" a) ["busy", "idle"] then field "status" a else "") <> "\"></i>" else "") <> "</span>"

mention :: Value -> String -> String
mention state id =
  let a = find (\item -> field "id" item == id) $ items "agents" state
  in if boolean a then "<button type=\"button\" class=\"entity-mention\" data-mention=\"" <> escape id <> "\" aria-label=\"Open chat with " <> escape (field "name" a) <> "\">@" <> escape (field "name" a) <> "</button>"
     else escape $ if id == "you" then "You" else id

openChat :: String -> Effect Unit
openChat id = do
  state <- read "state"
  let a = find (\item -> field "id" item == id) $ items "agents" state
  when (boolean a) do
    input <- q "#message-input"
    unless (boolean $ state .! "drafts") $ setField state "drafts" {}
    set (state .! "drafts") (field "selected" state) (input .! "value")
    setField state "selected" id
    setField state "panel" "chat"
    write "chatView" "conversation"
    fire "closeActivityMenus" []
    fire "showPane" [value "chat"]
    setField a "unread" false
    if field "kind" a == "group" then setField state "groupView" id *> setField state "scope" "groups"
    else do
      when (boolean (state .! "groupView") || field "scope" state == "groups") $ setField state "scope" "all"
      set state "groupView" null
    write "search" ""
    prop "#agent-search" "value" ""
    setField input "value" $ field id (state .! "drafts")
    fire "closeModal" []
    fire "setBrowserMenu" []
    fire "render" []
    viewport <- q "#conversation-body"
    set viewport "scrollTop" $ viewport .! "scrollHeight"

toast :: String -> Effect Unit
toast text = do
  node <- q "#toast"
  setField node "textContent" text
  toggle node "visible" true
  read "toastTimer" >>= cancelTimer
  timer <- delay 3200 $ toggle node "visible" false
  write "toastTimer" timer

modal :: String -> String -> String -> Effect Unit
modal title content eyebrow = do
  node <- q "#modal"
  toggle node "app-menu-sheet" false
  prop "#modal-eyebrow" "textContent" eyebrow
  putHTML "#modal-content" $ "<h2 id=\"modal-title\">" <> escape title <> "</h2>" <> content
  unless (boolean $ node .! "open") $ void $ call node "showModal" []

render :: Effect Unit
render = do
  node <- q "#modal"
  title <- q "#modal-title"
  when (boolean (node .! "open") && textOf title == "Shared computer") $ fire "computerDialog" []
  for_ ["renderPanes", "renderSidebar", "renderAgentHeader", "renderConversation", "renderTabs", "renderWorkspace", "renderGlobal", "save"] \name -> fire name []

setSearchOpen :: Boolean -> Effect Unit
setSearchOpen open = do
  q "#search-toggle" >>= \node -> attr node "aria-expanded" $ show open
  q "#corpora-search" >>= \node -> toggle node "search-open" open
  if open then q "#agent-search" >>= focus
  else write "search" "" *> prop "#agent-search" "value" "" *> renderSidebar

appMenu :: Effect Unit
appMenu = do
  identity <- q "#corpora-identity"
  owner <- q "#resource-owner"
  let row label target detail = "<button class=\"app-menu-row\" data-menu-target=\"" <> target <> "\"><span>" <> label <> "</span><span>" <> escape detail <> "</span></button>"
  modal (if textOf identity == "" then "CORPORA" else textOf identity)
    ("<nav aria-label=\"Corpora menu\">" <> row "Workspace & settings" "workspace-settings" "" <> row "Shared computer" "resource-button" (textOf owner) <> "</nav>") "MENU"
  q "#modal" >>= \node -> toggle node "app-menu-sheet" true

leaveGroup :: String -> Effect Unit
leaveGroup scopeName = do
  state <- read "state"
  set state "groupView" null
  openChat $ field "mainSapiId" state
  setField state "scope" scopeName
  limit <- exec "paneLimit" []
  when (int limit < 3) $ fire "showPane" [value "sidebar"] *> fire "renderPanes" []
  renderSidebar
  fire "save" []

renderSidebar :: Effect Unit
renderSidebar = do
  state <- read "state"
  search <- string <$> read "search"
  let agents = items "agents" state
      group = find (\g -> field "id" g == field "groupView" state && not (boolean $ g .! "archived")) agents
      hasGroups = A.any (\a -> field "kind" a == "group" && not (boolean $ a .! "archived")) agents
      pinned id = id == (if boolean group then field "lead" group else field "mainSapiId" state)
      count = show $ A.length $ A.filter (\a -> field "kind" a /= "group" && not (boolean $ a .! "retired") && not (boolean $ a .! "archived")) agents
  unless (boolean group) $ set state "groupView" null
  when (not hasGroups && field "scope" state == "groups") $ setField state "scope" "all"
  prop "#agent-count" "textContent" $ if CU.length count < 2 then "0" <> count else count
  buttons <- qa "[data-scope]"
  for_ buttons \button -> do
    let active = field "scope" (button .! "dataset") == field "scope" state
    toggle button "active" active
    toggle button "group-open" $ active && boolean group
    attr button "aria-pressed" $ show active
    setField button "disabled" $ field "scope" (button .! "dataset") == "groups" && not hasGroups
  let listed = A.sortBy (\a b -> case compare (pinned $ field "id" b) (pinned $ field "id" a) of
        EQ -> compare (number $ b .! "lastActivity") (number $ a .! "lastActivity")
        order -> order) $ A.filter (\a -> not (boolean $ a .! "retired") && not (boolean $ a .! "archived") &&
          (if boolean group then A.any (\id -> string id == field "id" a) (items "members" group) else field "scope" state == "all" || (field "scope" state == "groups") == (field "kind" a == "group")) &&
          S.contains (S.Pattern $ S.toLower search) (S.toLower $ field "name" a <> " " <> field "role" a)) agents
  rows <- traverse (\a -> do
    face <- avatar a (if pinned (field "id" a) then "main-sapi-avatar" else "") true
    labels <- if field "kind" a == "group" then do
      color <- exec "groupColor" [a .! "color"]
      let members = show $ A.length $ items "members" a
      pure $ "<span class=\"group-labels compact\" style=\"--label-count:1\"><span class=\"group-chip\" style=\"--group-color:" <> string color <> "\" title=\"" <> members <> " members\" aria-label=\"" <> members <> " members\"><span>" <> members <> "</span></span></span>"
    else do
      labels_ <- exec "groupLabels" [a, value true]
      timestamp <- construct (global .! "Date") [a .! "lastActivity"]
      time <- call timestamp "toLocaleTimeString" [value ([] :: Array Value), value {hour:"2-digit", minute:"2-digit", hour12:false}]
      pure $ string labels_ <> "<small>" <> escape (string time) <> "</small>"
    pure $ "<div class=\"agent-entry\"><div class=\"agent-row " <> (if field "id" a == field "selected" state then "active " else "") <>
      (if pinned (field "id" a) then "main-sapi-row " else "") <> (if field "kind" a == "group" then "group-row" else "") <> "\" data-agent=\"" <> escape (field "id" a) <> "\">" <> face <>
      "<div class=\"agent-row-copy\"><div class=\"agent-row-name\"><button class=\"agent-name\" data-agent=\"" <> escape (field "id" a) <> "\" aria-label=\"Open " <> escape (field "name" a) <>
      (if boolean group && pinned (field "id" a) then " · Lead" else "") <> "\" " <> (if field "id" a == field "selected" state then "aria-current=\"true\"" else "") <> ">" <> escape (field "name" a) <> "</button>" <> labels <>
      "</div><p>" <> (if boolean group && pinned (field "id" a) then "Lead · " else "") <> escape (if boolean group then field "role" a else string $ a .! "preview" <||> a .! "description" <||> value "Shared workspace") <> "</p></div></div></div>") listed
  putHTML "#agent-list" $ join rows
  fire "observeGroupLabels" []

main :: Effect Unit
main = do
  register "makeInitialState" \args -> pure $ initialState $ at 0 args
  register "agent" \args -> read "state" <#> \state -> agent state $ string $ at 0 args
  register "selected" \_ -> read "state" <#> \state -> agent state $ field "selected" state
  register "isMainSapi" \args -> read "state" <#> \state -> value $ field "id" (at 0 args) == field "mainSapiId" state
  register "avatar" \args -> value <$> avatar (at 0 args) (string $ at 1 args) (boolean $ at 2 args)
  register "mention" \args -> read "state" <#> \state -> value $ mention state $ string $ at 0 args
  register "openChat" \args -> openChat (string $ at 0 args) $> null
  register "toast" \args -> toast (string $ at 0 args) $> null
  register "modal" \args -> modal (string $ at 0 args) (string $ at 1 args) (string $ at 2 args <||> value "SAPI WORKSPACE") $> null
  register "closeModal" \_ -> q "#modal" >>= \node -> call node "close" []
  register "leaveGroup" \args -> leaveGroup (string $ at 0 args) $> null
  register "setSearchOpen" \args -> setSearchOpen (boolean $ at 0 args) $> null
  for_ [{name:"syncWorkspace", action:syncWorkspace}, {name:"renderSidebar", action:renderSidebar}, {name:"render", action:render}, {name:"appMenu", action:appMenu}] \entry ->
    register entry.name \_ -> entry.action $> null

mount :: Effect Unit
mount = do
  bootstrap <- read "bootstrap"
  state <- exec "makeInitialState" [bootstrap]
  let document = global .! "document"
      window = global .! "window"
  write "state" state
  write "workspaceOwner" $ state .! "selected"
  write "search" ""
  write "actions" $ value {"new-tab":callback (\_ -> exec "openNewTab" [])}
  let effect fn = callback \_ -> fn
  panes <- call (window .! "SapiensPanes") "mount" [value
    { syncWorkspace:effect $ fire "syncWorkspace" [] $> null
    , activeTab:effect $ read "state" <#> flip get "activeTab"
    , getPanes:effect $ read "state" <#> flip get "panes"
    , setPanes:callback \args -> read "state" >>= \s -> set s "panes" (at 0 args) $> null
    , selectedName:effect $ exec "selected" [] <#> flip get "name" }]
  for_ ["paneLimit", "showPane", "renderPanes", "resizeComposer", "syncMobileViewport"] \name -> write name $ panes .! name
  q "#search-toggle" >>= \node -> on node "click" false \_ -> getAttr node "aria-expanded" >>= setSearchOpen <<< (_ /= "true")
  q "#agent-search" >>= \node -> do
    on node "input" false \event -> write "search" (event .! "target" .! "value") *> renderSidebar
    on node "keydown" false \event -> do
      limit <- exec "paneLimit" []
      when (field "key" event == "Escape" && int limit < 3) do
        prevent event
        setSearchOpen false
        q "#search-toggle" >>= focus
  on document "click" false \event -> do
    button <- closest (event .! "target") "button,[data-agent]"
    when (boolean button) do
      current <- read "state"
      let d = button .! "dataset"
          pane = field "togglePane" d
      if boolean (d .! "menuTarget") then do
        fire "closeModal" []
        if field "menuTarget" d == "workspace-settings" then fire "autonomyDialog" []
        else do
          node <- call document "getElementById" [d .! "menuTarget"]
          when (boolean node) $ void $ call node "click" []
      else if pane /= "" then do
        if pane == "workspace" && not (boolean $ current .! "activeTab") then fire "openNewTab" []
        else do
          limit <- exec "paneLimit" []
          let count = A.length $ A.filter (\key -> boolean $ current .! "panes" .! key) $ keys (current .! "panes")
          if boolean (current .! "panes" .! pane) && (int limit == 3 || int limit == 2 && count > 1)
            then setField (current .! "panes") pane false else fire "showPane" [value pane]
          fire "renderPanes" []
          fire "save" []
      else if boolean (d .! "action") then do
        actions <- read "actions"
        when (boolean $ actions .! field "action" d) $ void $ invoke (actions .! field "action" d) []
      else if boolean (d .! "mention") then openChat $ field "mention" d
      else if boolean (d .! "agent") then do
        let group = find (\g -> field "id" g == field "groupView" current && not (boolean $ g .! "archived")) $ items "agents" current
        isName <- call button "matches" [value ".agent-name"]
        inList <- closest button "#agent-list"
        if not (boolean isName) && boolean inList && A.any (\id -> string id == field "agent" d) (items "members" group) then do
          openChat $ field "id" group
          input <- q "#message-input"
          let previous = find (\prefix -> T.test ("^" <> T.replace "[.*+?^${}()|[\\]\\\\]" "g" "\\$&" (string prefix)) "" (field "value" input)) $
                map (\id -> value $ "@" <> field "name" (agent current $ string id) <> " ") $ items "members" group
              text = "@" <> field "name" (agent current $ field "agent" d) <> " " <> CU.drop (CU.length $ string previous) (field "value" input)
          setField input "value" text
          setField (current .! "drafts") (field "id" group) text
          focus input
          fire "save" []
        else openChat $ field "agent" d
      else if boolean (d .! "scope") && not (boolean $ button .! "disabled") then leaveGroup $ field "scope" d
      else if A.elem (field "panel" d) ["chat", "tasks", "notes", "work", "updates"] && not (boolean $ button .! "disabled") then do
        set current "panel" $ d .! "panel"
        when (field "panel" d == "work") $ fire "selectDefaultWorkView" []
        when (field "panel" d == "chat") $ write "chatView" "conversation"
        when (field "panel" d == "updates") $ write "updatesView" "events"
        fire "closeActivityMenus" []
        fire "renderConversation" []
        fire "save" []
      else if boolean (d .! "tab") then fire "browserAction" [value "focus", value {id:d .! "tab"}]
      else when (boolean $ d .! "closeTab") $ fire "browserAction" [value "close", value {id:d .! "closeTab"}]
  on document "submit" false \event -> when (field "id" (event .! "target") == "chat-form") do
    prevent event
    input <- q "#message-input"
    fire "sendChat" [input .! "value"]
  q "#close-modal" >>= \node -> on node "click" false $ const $ fire "closeModal" []
  q "#modal" >>= \node -> on node "click" false \event -> when (same node (event .! "target")) do
    rect <- call node "getBoundingClientRect" []
    when (number (event .! "clientX") < number (rect .! "left") || number (event .! "clientX") > number (rect .! "right") || number (event .! "clientY") < number (rect .! "top") || number (event .! "clientY") > number (rect .! "bottom")) $ fire "closeModal" []
  for_ [{selector:"#add-agent", action:"addAgent"}, {selector:"#resource-button", action:"computerDialog"}] \entry ->
    q entry.selector >>= \node -> on node "click" false $ const $ fire entry.action []
  q "#message-input" >>= \node -> on node "keydown" false \event ->
    when (field "key" event == "Enter" && not (boolean $ event .! "shiftKey") && not (boolean $ event .! "isComposing")) $ prevent event *> fire "sendChat" [event .! "target" .! "value"]
  q ".wordmark" >>= \node -> on node "click" false \event -> do
    prevent event
    current <- read "state"
    setField current "panes" {sidebar:true,chat:true,workspace:true}
    fire "showPane" [value "chat"]
    fire "renderPanes" []
    fire "save" []
  on document "keydown" false \event -> do
    dialog <- q "#modal"
    when (field "key" event == "/" && not (A.elem (field "tagName" $ document .! "activeElement") ["INPUT", "TEXTAREA", "SELECT"]) && not (boolean $ dialog .! "open")) do
      prevent event
      fire "showPane" [value "sidebar"]
      fire "renderPanes" []
      fire "save" []
      setSearchOpen true

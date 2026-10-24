module Sapiens.Conversation (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Number (abs)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Int as Int
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Aff (try)
import Data.Either (Either(..))
import Effect.Exception (message)
import Sapiens.Runtime
import Sapiens.Text as T

attention :: String -> Boolean
attention status = A.elem status ["failed", "interrupted", "conflict"]

blocks :: Value -> Boolean
blocks turn = A.elem (field "status" turn) ["queued", "running", "output_pending"]

statuses :: Value
statuses = value {output_pending:"Awaiting output pulse", queued:"Queued", running:"Running", done:"Completed", warning:"Warning", failed:"Failed", interrupted:"Interrupted", conflict:"Needs review", cancelled:"Dismissed"}

displayTime :: Value -> Effect String
displayTime timestamp = do
  date_ <- construct (global .! "Date") [timestamp]
  string <$> call date_ "toLocaleTimeString" [value ([] :: Array Value),value {hour:"2-digit", minute:"2-digit"}]

chatResult :: Value -> Value
chatResult turn =
  let text = field "output" turn
      notice = A.head $ T.matches "^Warning — partial result\\.\n\n(Saved: [\\s\\S]+?)\n\n(The (?:tool|time) limit was reached after [\\s\\S]+)$" "" text
  in if field "status" turn /= "warning" then value {text} else value
    {text:fromMaybe text $ notice >>= T.group 1, warning:fromMaybe (string $ turn .! "error" <||> value "Partial result; review before relying on it.") $ notice >>= T.group 2}

requestStatus :: Value -> Value
requestStatus turn
  | not (attention $ field "status" turn) && field "status" turn /= "cancelled" = null
  | otherwise =
      let error = field "error" turn
          reason = if T.test "TimeoutError|time limit|exceeded \\d+(?:\\.\\d+)?s" "i" error then "Timed out" else if T.test "tool-step limit|tool limit" "i" error then "Tool limit reached" else ""
          detail = fromMaybe "" $ A.head $ S.split (S.Pattern "\n") error
      in value {label:if reason == "" then field (field "status" turn) statuses else reason <> if field "status" turn == "cancelled" then " · Dismissed" else ""
        ,detail:if detail /= "" then detail else if field "status" turn == "cancelled" then "This request was dismissed." else "This request needs attention."}

turnActions :: Value -> Effect String
turnActions turn = do
  live <- read "live"
  online <- boolean <$> read "online"
  let status = field "status" turn
      current = live .! "run_activity" .! string (turn .! "batch_id" <||> turn .! "id") <||> live .! "activity" .! field "agent" turn
      button action label disabled = "<button class=\"button\" data-live-turn=\"" <> action <> "\" data-id=\"" <> escape (field "id" turn) <> "\" data-owner=\"" <> escape (field "agent" turn) <> "\" " <> (if disabled then "disabled" else "") <> ">" <> label <> "</button>"
  pure $ if status == "running" then "<div class=\"actions\">" <> button "cancel" "Stop" (not online || boolean (current .! "stopping")) <> "<small>Already completed actions are not undone.</small></div>"
    else if attention status then "<div class=\"actions\">" <> button "retry" "Retry" false <> button "cancel" "Dismiss" false <> "</div>"
    else if status == "queued" then "<div class=\"actions\">" <> button "cancel" "Cancel queued turn" false <> "</div>" else ""

turnProgress :: Value -> Value -> Effect String
turnProgress turn timestamp = do
  live <- read "live"
  online <- boolean <$> read "online"
  time <- if same timestamp null then now else pure $ number timestamp
  let current = live .! "run_activity" .! string (turn .! "batch_id" <||> turn .! "id") <||> live .! "activity" .! field "agent" turn
      active = if field "turn" current == field "id" turn then current else value {}
      elapsed = max 0 $ Int.floor $ (time - number (active .! "started" <||> value (dateNumber $ field "created" turn))) / 1000.0
      quiet = max 0 $ Int.floor $ (time - number (active .! "updated" <||> active .! "started" <||> value time)) / 1000.0
      phase = if not online then "Disconnected" else if boolean (active .! "stopping") then "Stopping…" else if field "status" turn == "output_pending" then "Awaiting output pulse" else if field "status" turn == "queued" then "Queued" else string $ active .! "phase" <||> value "Starting model"
      detail = if boolean (active .! "tool") then "Current tool: " <> field "tool" active else if boolean (active .! "last_action") then "Last completed action: " <> field "last_action" active else ""
  pure $ "<strong>" <> escape phase <> " · " <> show elapsed <> "s</strong><p>" <> escape detail <> "</p>" <> if quiet >= 60 then "<small>No recent update · " <> show quiet <> "s since last activity</small>" else ""

updateProgress :: Effect Unit
updateProgress = do
  live <- read "live"
  qa "[data-turn-progress]" >>= flip for_ (\node -> do
    let turn = find (\t -> field "id" t == field "turnProgress" (node .! "dataset")) $ items "turns" live
    when (boolean turn) $ turnProgress turn null >>= html node)

applySnapshot :: Value -> Effect Unit
applySnapshot snapshot = do
  identity <- q "#corpora-identity"
  when (boolean identity && boolean (snapshot .! "corpora")) do
    setField identity "hidden" false
    set identity "textContent" $ snapshot .! "corpora" .! "name"
    set identity "title" $ snapshot .! "corpora" .! "id"
  fire "receiveWorkspaces" [snapshot .! "preferences"]
  write "live" snapshot
  state <- read "state"
  let old = items "agents" state
      agents = map (\a -> merge [find (\item -> field "id" item == field "id" a) old,a,value {kind:"sapi",scope:"personal",autonomy:"assist",status:"online",lastActivity:dateNumber $ field "created" a,preview:"Ready for your message."}]) $ items "agents" snapshot
  setField state "agents" agents
  setField state "messages" {}
  for_ (items "turns" snapshot) \turn -> unless (boolean $ turn .! "group") do
    let id = field "agent" turn
        timestamp = dateNumber $ field "created" turn
        human = A.elem (field "flow" turn) ["chat", "computer"]
        a = find (\item -> field "id" item == id) agents
    unless (boolean $ state .! "messages" .! id) $ setField (state .! "messages") id ([] :: Array Value)
    when human do
      time <- displayTime $ turn .! "created"
      let messages = items id $ state .! "messages"
      setField (state .! "messages") id $ A.snoc messages $ value {role:"user",author:turn .! "origin" .! "caller",text:turn .! "input",time,timestamp,attachments:turn .! "attachments",requestTurn:turn}
      when (A.elem (field "status" turn) ["done", "warning"] && not (same (turn .! "output") null)) do
        outputTime <- displayTime $ turn .! "output_at" <||> turn .! "created"
        setField (state .! "messages") id $ A.snoc (items id $ state .! "messages") $ merge [value {role:"assistant",time:outputTime,timestamp:dateNumber $ string $ turn .! "output_at" <||> turn .! "created",outputOrder:turn .! "output_order",turnId:turn .! "id"},chatResult turn]
      when (boolean a) do
        setField a "lastActivity" timestamp
        setField a "preview" $ CU.take 150 $ T.replace "\\s+" "g" " " $ if A.elem (field "status" turn) ["done", "warning"] && not (same (turn .! "output") null) then field "text" $ chatResult turn else field "input" turn
    when (boolean a && field "status" turn == "running") $ setField a "status" "busy"
  for_ (items "groups" snapshot) \group -> do
    setField state "agents" $ A.snoc (items "agents" state) $ merge [group,value {status:if A.any (\r -> field "status" r == "running") (items "requests" group) then "busy" else "online"
      ,lastActivity:dateNumber $ field "updated" group, preview:(fromMaybe null $ A.last $ items "messages" group) .! "text" <||> group .! "description" <||> value "Shared workspace"}]
    messages <- traverse (\m -> do
      time <- displayTime $ m .! "created"
      pure $ value {role:if field "author" m == "admin" then "user" else "assistant",author:if field "author" m == "admin" then null else m .! "author",text:m .! "text",time,timestamp:dateNumber $ field "created" m}) $ items "messages" group
    setField (state .! "messages") (field "id" group) messages
  fire "delegationMessages" [snapshot]
  for_ (keys $ state .! "messages") \id -> setField (state .! "messages") id $ A.sortBy (\a b -> case compare (number $ a .! "timestamp") (number $ b .! "timestamp") of
    EQ -> compare (number $ a .! "outputOrder") (number $ b .! "outputOrder")
    order -> order) $ items id $ state .! "messages"
  let selected = find (\a -> field "id" a == field "selected" state) $ items "agents" state
      previous = find (\a -> field "id" a == field "selected" state) old
  when (not (boolean selected) || boolean (selected .! "retired") && not (boolean $ previous .! "retired")) do
    input <- q "#message-input"
    set (state .! "drafts") (field "selected" state) (input .! "value")
    set state "selected" $ snapshot .! "main_agent_id"
    setField input "value" $ field (field "selected" state) (state .! "drafts")
    fire "renderTabs" []
    fire "renderWorkspace" []

renderGlobal :: Effect Unit
renderGlobal = do
  live <- read "live"
  online <- boolean <$> read "online"
  unless (boolean $ global .! "window" .! "SapiensConnections") do
    prop "#connection-label" "textContent" $ "Local · " <> if online then "Online" else "Reconnecting…"
    node <- q "#connection-status"
    setField (node .! "dataset") "online" $ show online
  let owner = live .! "computer" .! "owner"
  text <- if boolean owner then exec "agent" [owner] <#> \a -> "In use · " <> field "name" a else pure $ if boolean (live .! "computer" .! "built") then "Blindly4 · Available" else "Blindly4 · Build required"
  prop "#resource-owner" "textContent" text
  node <- q "#resource-status"
  toggle node "idle" $ not $ boolean owner
  toggle node "paused" false

renderHeader :: Effect Unit
renderHeader = do
  a <- exec "selected" []
  live <- read "live"
  online <- boolean <$> read "online"
  submitting <- map string <<< array <$> read "submitting"
  uploading <- int <$> read "uploading"
  main <- exec "isMainSapi" [a]
  face <- exec "avatar" [a,value $ if boolean main then "large main-sapi-avatar" else "large",value true]
  labels <- if field "kind" a == "group" then pure "" else string <$> exec "groupLabels" [a]
  putHTML "#agent-heading" $ string face <> "<div><div class=\"agent-title\"><h2>" <> escape (field "name" a) <> "</h2>" <> labels <> "</div><p class=\"agent-role\">" <> escape (if field "kind" a == "group" then field "description" a else field "role" a) <> "</p></div><button class=\"icon-button\" data-action=\"agent-settings\" aria-label=\"Sapi settings\">···</button>"
  limit <- exec "paneLimit" []
  prop "#message-input" "placeholder" $ if int limit < 3 then "Message…" else "Message " <> field "name" a <> "…"
  q "#message-input" >>= \node -> attr node "aria-label" $ "Message " <> field "name" a
  fire "resizeComposer" []
  fire "renderActivityNavigation" []
  prop "#attach-button" "hidden" $ boolean $ a .! "archived"
  prop ".send-button" "disabled" $ boolean (a .! "retired") || boolean (a .! "archived") || A.elem (field "status" $ live .! "corpora") ["paused", "archived"] || not online || A.elem (field "id" a) submitting || uploading > 0

renderMessages :: Value -> Effect Unit
renderMessages host = do
  state <- read "state"
  a <- exec "selected" []
  warnings <- map string <<< array <$> read "expandedWarnings"
  let messages = items (field "id" a) $ state .! "messages"
  prop "#composer-area" "hidden" $ field "panel" state /= "chat"
  rows <- traverse (\m -> do
    let user = field "role" m == "user"
        request = m .! "requestTurn"
        status = requestStatus request
        key = if boolean (m .! "delegation") then "delegation:" <> field "id" (m .! "delegation") else field "role" m <> ":" <> string (request .! "id" <||> m .! "turnId")
        requestKey = "request-" <> field "id" request
        requestExpanded = A.elem requestKey warnings
        warningExpanded = A.elem (field "turnId" m) warnings
        badge id controls title expanded = "<button type=\"button\" class=\"warning-badge\" data-warning-toggle=\"" <> escape id <> "\" aria-expanded=\"" <> show expanded <> "\" aria-controls=\"" <> escape controls <> "\">" <> escape title <> "</button>"
    face <- if user then pure "<span>↗</span>" else string <$> exec "avatar" [a,value "mini"]
    name <- if boolean (m .! "author") then exec "agent" [m .! "author"] <#> escape <<< field "name"
      else if user then pure "Admin" else string <$> exec "mention" [a .! "id"]
    text <- string <$> exec "formatText" [m .! "text"]
    actions <- turnActions request
    attachments <- if user then traverse (\item -> string <$> exec "attachmentLabel" [item]) (items "attachments" m) else pure []
    pure $ "<div data-chat-key=\"" <> escape key <> "\" class=\"message " <> (if user then "user " else "") <> (if boolean (m .! "warning") then "warning-message" else "") <> "\"><div class=\"message-meta\">" <> face <> "<strong>" <> name <> "</strong><time>" <> escape (field "time" m) <> "</time>" <>
      (if boolean status then badge requestKey requestKey (field "label" status) requestExpanded else "") <> (if boolean (m .! "warning") then badge (field "turnId" m) ("warning-" <> field "turnId" m) "Warning" warningExpanded else "") <> "</div><div class=\"message-bubble\">" <>
      (if boolean (m .! "warning") then "<div class=\"warning-details\" id=\"warning-" <> escape (field "turnId" m) <> "\" " <> (if warningExpanded then "" else "hidden") <> ">" <> escape (field "warning" m) <> "</div>" else "") <>
      (if boolean status then "<div class=\"warning-details\" id=\"" <> escape requestKey <> "\" " <> (if requestExpanded then "" else "hidden") <> "><p>" <> escape (field "detail" status) <> "</p><p>No final reply was saved for this request.</p>" <> actions <> "</div>" else "") <>
      join (map (\p -> "<p>" <> T.replace "\n" "g" "<br>" p <> "</p>") $ S.split (S.Pattern "\n\n") text) <>
      (if boolean (m .! "delegation") && boolean request && blocks request then actions else "") <>
      (if A.null attachments then "" else "<div class=\"message-attachments\">" <> join attachments <> "</div>") <> "</div></div>") messages
  html host $ "<div class=\"day-divider\">CONVERSATION</div>" <> join rows
  fire "renderAttachment" []
  fire "taskCallControls" [host]
  when (A.null messages) $ element "div" "empty" "Start a conversation." >>= \node -> append host [node]
  live <- read "live"
  for_ (A.filter (\turn -> field "agent" turn == field "selected" state && blocks turn && (not (boolean $ turn .! "batch_id") || same (turn .! "batch_id") (turn .! "id"))) $ items "turns" live) \turn -> do
    progress <- turnProgress turn null
    actions <- turnActions turn
    node <- element "section" "live-status" ""
    setField (node .! "dataset") "chatKey" $ "progress:" <> field "id" turn
    html node $ "<div data-turn-progress=\"" <> escape (field "id" turn) <> "\">" <> progress <> "</div>" <> actions
    append host [node]

commitChat :: Value -> Value -> Boolean -> Boolean -> Number -> Value -> Effect Unit
commitChat viewport content changedView bottom scroll anchor = do
  equal <- if boolean (viewport .! "lastElementChild") then call (viewport .! "lastElementChild") "isEqualNode" [content .! "lastElementChild"] else pure $ value false
  let latestChanged = changedView || not (boolean equal)
      key node index = string $ node .! "dataset" .! "chatKey" <||> value (field "className" node <> ":" <> show index)
      existing = A.mapWithIndex (\index node -> {key:key node index, node}) $ array $ viewport .! "children"
  -- Keep a cursor and stable keyed children; no scroll write for an unchanged poll.
  record <- pure $ value {cursor:viewport .! "firstElementChild", changed:changedView, keep:[] :: Array Value}
  for_ (A.mapWithIndex (\index node -> {index,node}) $ array $ content .! "children") \entry -> do
    let fresh = entry.node
        old = if changedView then null else (fromMaybe {key:"",node:null} $ A.find (\item -> item.key == key fresh entry.index) existing).node
    identical <- if boolean old then call old "isEqualNode" [fresh] else pure $ value false
    let node = if boolean identical then old else fresh
    when (boolean old && not (same node old)) do
      setField record "changed" true
      when (same (record .! "cursor") old) $ set record "cursor" fresh
      void $ call old "replaceWith" [fresh]
      disposeTree old
    when (boolean identical) $ disposeTree fresh
    unless (same node (record .! "cursor")) do
      void $ call viewport "insertBefore" [node,record .! "cursor"]
      setField record "changed" true
    set record "cursor" $ node .! "nextElementSibling"
    setField record "keep" $ A.snoc (items "keep" record) node
  for_ (array $ viewport .! "children") \node -> unless (A.any (same node) $ items "keep" record) do
    void $ call node "remove" []
    disposeTree node
    setField record "changed" true
  target <- if bottom && boolean (record .! "changed") && latestChanged then pure $ number (viewport .! "scrollHeight") - number (viewport .! "clientHeight")
    else if boolean (anchor .! "node" .! "isConnected") then do
      rect <- call (anchor .! "node") "getBoundingClientRect" []
      pure $ number (viewport .! "scrollTop") + number (rect .! "top") - number (anchor .! "top")
    else pure scroll
  when (abs (number (viewport .! "scrollTop") - target) > 1.0) $ setField viewport "scrollTop" target

renderConversation :: Effect Unit
renderConversation = defer \_ -> unless (boolean $ global .! "document" .! "hidden") do
  state <- read "state"
  viewport <- q "#conversation-body"
  when (A.elem (field "panel" state) ["tasks", "notes"]) do
    write "workView" $ if field "panel" state == "notes" then "memo" else "tasks"
    setField state "panel" "work"
  toggle viewport "notes-view" $ field "panel" state == "notes"
  workView <- string <$> read "workView"
  chatView <- string <$> read "chatView"
  updatesView <- string <$> read "updatesView"
  rendered <- string <$> read "renderedConversation"
  let key = field "selected" state <> ":" <> field "panel" state <> ":" <> if field "panel" state == "work" then workView else if field "panel" state == "chat" then chatView else updatesView
      changedView = rendered /= key
      scroll = if changedView then 0.0 else number $ viewport .! "scrollTop"
      bottom = field "panel" state == "chat" && (changedView || number (viewport .! "scrollHeight") - number (viewport .! "scrollTop") - number (viewport .! "clientHeight") < 80.0)
      chat = field "panel" state == "chat" && chatView == "conversation"
  when changedView $ write "lastChatGeometry" null
  write "renderedConversation" key
  rect <- call viewport "getBoundingClientRect" []
  nodes <- traverse (\node -> do
    box <- call node "getBoundingClientRect" []
    pure {node,box}) $ array $ viewport .! "children"
  let visible = A.find (\entry -> number (entry.box .! "bottom") > number (rect .! "top")) nodes
      anchor = if changedView then null else case visible of
        Nothing -> null
        Just entry -> value {node:entry.node,top:entry.box .! "top"}
  host <- if chat then element "div" "" "" else pure viewport
  collection <- exec "renderChatCollection" [host]
  if boolean collection then renderHeader *> renderGlobal else do
    selected <- exec "selected" []
    if field "kind" selected == "group" then fire "renderGroupPanel" [host]
    else if A.elem (field "panel" state) ["work", "updates"] then fire "renderWork" [host]
    else when (field "panel" state == "chat") $ renderMessages host
    renderHeader
    renderGlobal
    if chat then commitChat viewport host changedView bottom scroll anchor *> fire "restoreChatPosition" []
    else when changedView $ setField viewport "scrollTop" 0

sendChat :: String -> Effect Unit
sendChat raw = do
  state <- read "state"
  selected <- exec "selected" []
  submitting <- map string <<< array <$> read "submitting"
  uploading <- int <$> read "uploading"
  drafts <- read "attachmentDrafts"
  let text = S.trim raw
      id = field "selected" state
      attachments = items id drafts
  unless ((text == "" && A.null attachments) || A.elem id submitting || uploading > 0) do
    write "submitting" $ A.snoc submitting id
    renderHeader
    report do
      outcome <- try do
        clarification <- liftEffect $ read "clarificationWorkload"
        let body = merge [value {text, attachments:map (flip get "id") attachments}, if field "owner" clarification == id then value {workload:clarification .! "id"} else value {}]
        void $ request ("/api/" <> (if field "kind" selected == "group" then "groups" else "agents") <> "/" <> id <> "/messages") "POST" body
        liftEffect do
          write "clarificationWorkload" null
          setField drafts id $ A.filter (\a -> not $ A.any (\sent -> same (sent .! "id") (a .! "id")) attachments) $ items id drafts
          fire "renderAttachment" []
          when (S.trim (field id $ state .! "drafts") == text) $ setField (state .! "drafts") id ""
          input <- q "#message-input"
          latest <- read "state"
          when (field "selected" latest == id && S.trim (field "value" input) == text) $ setField input "value" "" *> setField (state .! "drafts") id ""
          fire "closeMentions" []
          fire "save" []
        void $ await $ exec "refresh" []
      liftEffect do
        current <- map string <<< array <$> read "submitting"
        write "submitting" $ A.filter (_ /= id) current
        renderHeader
        case outcome of
          Left error -> fire "toast" [value $ message error]
          Right _ -> pure unit

main :: Effect Unit
main = do
  write "submitting" ([] :: Array String)
  write "expandedWarnings" ([] :: Array String)
  write "renderedConversation" ""
  write "statusNames" statuses
  register "blocksChat" \args -> pure $ value $ blocks $ at 0 args
  register "chatResult" \args -> pure $ chatResult $ at 0 args
  register "requestStatus" \args -> pure $ requestStatus $ at 0 args
  register "displayTime" \args -> value <$> displayTime (at 0 args)
  register "turnActions" \args -> value <$> turnActions (at 0 args)
  register "turnProgress" \args -> value <$> turnProgress (at 0 args) (at 1 args)
  register "applySnapshot" \args -> applySnapshot (at 0 args) $> null
  register "sendChat" \args -> sendChat (string $ at 0 args) $> null
  register "getMessages" \args -> read "state" <#> \state -> state .! "messages" .! string (at 0 args) <||> value ([] :: Array Value)
  register "renderMessages" \args -> renderMessages (at 0 args) $> null
  register "commitChat" \args -> commitChat (at 0 args) (at 1 args) (boolean $ at 2 args) (boolean $ at 3 args) (number $ at 4 args) (at 5 args) $> null
  for_ [{name:"renderGlobal",action:renderGlobal},{name:"renderAgentHeader",action:renderHeader},{name:"renderConversation",action:renderConversation},{name:"updateProgress",action:updateProgress}] \entry -> register entry.name \_ -> entry.action $> null
  register "mountConversation" \_ -> do
    on (global .! "document") "click" false \event -> do
      button <- closest (event .! "target") "[data-warning-toggle]"
      when (boolean button) do
        warnings <- map string <<< array <$> read "expandedWarnings"
        let id = field "warningToggle" $ button .! "dataset"
            expanded = not $ A.elem id warnings
        write "expandedWarnings" $ (if expanded then [id] else []) <> A.filter (_ /= id) warnings
        attr button "aria-expanded" $ show expanded
        controls <- getAttr button "aria-controls"
        node <- call (global .! "document") "getElementById" [value controls]
        setField node "hidden" $ not expanded
    on (global .! "window") "sapiens-connection-change" false \_ -> do
      let connections = global .! "window" .! "SapiensConnections"
      when (boolean connections) $ write "online" $ boolean (connections .! "connected") && not (boolean $ connections .! "busy")
      renderGlobal
      renderHeader
    pure null

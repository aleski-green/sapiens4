module Sapiens.Session (main, mount, api) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Aff (Aff, try)
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Data.Either (Either(..))
import Sapiens.Async (toPromise)
import Sapiens.Runtime

connections :: Value
connections = global .! "window" .! "SapiensConnections"

api :: String -> String -> Value -> Aff Value
api path method data_ = do
  generation <- liftEffect $ pure $ connections .! "generation"
  timeout <- liftEffect $ call (global .! "AbortSignal") "timeout" [value 15000]
  let options = merge [value {method, headers:value {"Content-Type":"application/json", "X-Sapiens-Local":"1"}, signal:timeout}
        , if same data_ null then value {} else value {body:stringify data_}]
  response <- await $ if boolean connections then call connections "fetch" [value path,options] else call global "fetch" [value path,options]
  unless (same generation (connections .! "generation")) $ liftEffect $ throw "Workspace changed"
  result <- await $ call response "json" []
  unless (boolean $ response .! "ok") $ liftEffect $ throw $ string $ result .! "error" <||> value ("Request failed (" <> field "status" response <> ")")
  pure result

preferences :: Effect Value
preferences = do
  state <- read "state"
  drafts <- read "attachmentDrafts"
  pure $ value {selected:state .! "selected",panel:state .! "panel",scope:state .! "scope",groupView:state .! "groupView",panes:state .! "panes",drafts:state .! "drafts"
    ,attachment_drafts:object $ map (\id -> {key:id,value:value $ map (flip get "id") $ items id drafts}) $ keys drafts}

chatPosition :: Effect Value
chatPosition = do
  pending <- read "pendingChatPosition"
  if boolean pending then pure pending else do
    state <- read "state"
    view <- string <$> read "chatView"
    viewport <- q "#conversation-body"
    previous <- read "lastChatPosition"
    geometry <- string <$> read "lastChatGeometry"
    let currentGeometry = field "clientWidth" viewport <> ":" <> field "clientHeight" viewport
    if field "panel" state /= "chat" || view /= "conversation" then pure null
    else if boolean (global .! "document" .! "hidden") || not (boolean $ viewport .! "clientHeight") then pure previous
    else if field "selected" previous == field "selected" state && geometry /= "" && geometry /= currentGeometry then pure previous
    else do
      write "lastChatGeometry" currentGeometry
      top <- call viewport "getBoundingClientRect" [] <#> number <<< flip get "top"
      entries <- traverse (\node -> do
        rect <- call node "getBoundingClientRect" []
        pure {node,rect}) $ array $ viewport .! "children"
      let visible = fromMaybe {node:null,rect:null} $ A.find (\entry -> boolean (entry.node .! "dataset" .! "chatKey") && number (entry.rect .! "bottom") > top) entries
          result = value {selected:state .! "selected", bottom:number (viewport .! "scrollHeight") - number (viewport .! "scrollTop") - number (viewport .! "clientHeight") < 2.0
            ,key:visible.node .! "dataset" .! "chatKey", offset:if boolean visible.node then number (visible.rect .! "top") - top else 0.0}
      write "lastChatPosition" result
      pure result

restorePosition :: Effect Unit
restorePosition = do
  saved <- read "pendingChatPosition"
  unless (not (boolean saved) || boolean (global .! "document" .! "hidden")) do
    state <- read "state"
    view <- string <$> read "chatView"
    viewport <- q "#conversation-body"
    if field "selected" saved /= field "selected" state || field "panel" state /= "chat" || view /= "conversation" then write "pendingChatPosition" null
    else when (boolean $ viewport .! "clientHeight") do
      let node = find (\n -> same (n .! "dataset" .! "chatKey") (saved .! "key")) $ array $ viewport .! "children"
      when (boolean (saved .! "bottom") || boolean node) do
        target <- if boolean (saved .! "bottom") then pure $ number (viewport .! "scrollHeight") - number (viewport .! "clientHeight")
          else do
            rect <- call node "getBoundingClientRect" []
            parent <- call viewport "getBoundingClientRect" []
            pure $ number (viewport .! "scrollTop") + number (rect .! "top") - number (parent .! "top") - number (saved .! "offset")
        setField viewport "scrollTop" target
        write "lastChatPosition" saved
        write "lastChatGeometry" $ field "clientWidth" viewport <> ":" <> field "clientHeight" viewport
        resuming <- boolean <$> read "resumingChat"
        unless resuming $ write "pendingChatPosition" null

workspacePreferences :: Effect Value
workspacePreferences = do
  prefs <- preferences
  state <- read "state"
  viewport <- q "#conversation-body"
  position <- chatPosition
  pure $ merge [prefs,value {workspaces:state .! "workspaces",scroll:viewport .! "scrollTop",chatPosition:position}]

saveLocal :: Effect Unit
saveLocal = when (boolean connections) do
  prefs <- workspacePreferences
  void $ call connections "save" [prefs]

save :: Effect Unit
save = do
  saveLocal
  read "saveTimer" >>= cancelTimer
  delay 300 (report flushPreferences) >>= write "saveTimer"

flushPreferences :: Aff Unit
flushPreferences = do
  saving <- liftEffect $ boolean <$> read "saving"
  online <- liftEffect $ boolean <$> read "online"
  unless (saving || not online || boolean (connections .! "busy")) do
    prefs <- liftEffect preferences
    let serialized = stringify prefs
    saved <- liftEffect $ string <$> read "savedPreferences"
    when (serialized /= saved) do
      liftEffect $ write "saving" true
      result <- try do
        response <- api "/api/preferences" "PUT" $ if boolean connections then value {attachment_drafts:prefs .! "attachment_drafts"} else prefs
        liftEffect $ fire "receiveWorkspaces" [response .! "preferences"] *> write "savedPreferences" serialized
      liftEffect do
        case result of
          Left error -> fire "toast" [value $ "Settings are not saved yet: " <> message error]
          Right _ -> pure unit
        write "saving" false
        current <- stringify <$> preferences
        latest <- string <$> read "savedPreferences"
        when (current /= latest) $ delay 2000 (report flushPreferences) >>= write "saveTimer"

refresh :: Effect Value
refresh = do
  running <- read "refreshing"
  if boolean running then pure running else do
    let generation = connections .! "generation"
    promise <- toPromise do
      outcome <- try do
        snapshot <- api "/api/state" "GET" null
        when (same generation (connections .! "generation")) $ liftEffect do
          when (boolean connections) $ void $ call connections "snapshot" [snapshot]
          live <- read "live"
          online <- boolean <$> read "online"
          revision <- number <$> read "workspaceRevision"
          let changed = A.any (\key -> stringify (snapshot .! key) /= stringify (live .! key)) ["corpora", "agents", "groups", "turns", "computer", "orchestration", "activity", "run_activity", "workloads", "pulses", "routines", "events"]
              tabsChanged = number (snapshot .! "preferences" .! "workspace_revision") > revision
          write "online" true
          fire "applySnapshot" [snapshot]
          if tabsChanged then fire "renderTabs" [] *> fire "renderWorkspace" [] else fire "refreshWorkspacePreview" []
          when (changed || not online) do
            fire "renderSidebar" []
            fire "renderConversation" []
            fire "renderGlobal" []
            modal <- q "#modal"
            title <- q "#modal-title"
            when (boolean (modal .! "open") && textOf title == "Shared computer") $ fire "computerDialog" []
      liftEffect do
        case outcome of
          Left error | same generation (connections .! "generation") -> do
            write "online" false
            when (boolean connections) $ void $ call connections "offline" [value error]
            fire "renderGlobal" []
            fire "renderAgentHeader" []
          _ -> pure unit
        write "refreshing" null
      pure null
    write "refreshing" promise
    pure $ value promise

poll :: Effect Unit
poll = report do
  void $ await refresh
  liftEffect do
    fire "updateProgress" []
    online <- boolean <$> read "online"
    void $ delay (if boolean (connections .! "remote") then 2000 else if online then 750 else 2000) poll

workspaceSave :: Effect Unit
workspaceSave = do
  state <- read "state"
  input <- q "#message-input"
  set (state .! "drafts") (field "selected" state) (input .! "value")
  saveLocal

suspend :: Effect Unit
suspend = do
  frameId <- read "resumeChatFrame"
  void $ call global "cancelAnimationFrame" [frameId]
  write "resumingChat" false
  chatPosition >>= write "pendingChatPosition"
  workspaceSave

resume :: Effect Unit
resume = defer \_ -> unless (boolean $ global .! "document" .! "hidden") do
  frameId <- read "resumeChatFrame"
  void $ call global "cancelAnimationFrame" [frameId]
  write "resumingChat" true
  fire "syncMobileViewport" []
  fire "renderConversation" []
  frame (do
    restorePosition
    frame (write "resumingChat" false *> restorePosition) >>= write "resumeChatFrame") >>= write "resumeChatFrame"
  void refresh

main :: Effect Unit
main = do
  registerAsync "api" \args -> api (string $ at 0 args) (string $ at 1 args <||> value "GET") (at 2 args)
  register "preferences" \_ -> preferences
  register "workspacePreferences" \_ -> workspacePreferences
  register "chatPosition" \_ -> chatPosition
  register "refresh" \_ -> refresh
  registerAsync "flushPreferences" \_ -> flushPreferences $> null
  for_ [{name:"save",action:save},{name:"restoreChatPosition",action:restorePosition},{name:"suspendChat",action:suspend},{name:"resumeChat",action:resume}] \entry -> register entry.name \_ -> entry.action $> null

mount :: Effect Unit
mount = do
  bootstrap <- read "bootstrap"
  write "live" bootstrap
  write "online" $ if boolean connections then boolean (connections .! "connected") else true
  write "refreshing" null
  write "saving" false
  write "savedPreferences" ""
  write "pendingChatPosition" $ bootstrap .! "preferences" .! "chatPosition"
  write "lastChatPosition" $ bootstrap .! "preferences" .! "chatPosition"
  write "lastChatGeometry" null
  write "resumingChat" false
  let window = global .! "window"
      document = global .! "document"
  state <- read "state"
  prop "#message-input" "value" $ field (field "selected" state) $ state .! "drafts"
  q "#message-input" >>= \node -> on node "input" false \_ -> do
    current <- read "state"
    set (current .! "drafts") (field "selected" current) (node .! "value")
    save
  q ".wordmark" >>= \node -> on node "click" false \_ -> do
    current <- read "state"
    let mainSapi = find (\a -> same (a .! "id") (current .! "mainSapiId")) $ items "agents" current
    when (boolean mainSapi) $ fire "openChat" [mainSapi .! "id"]
  setField window "sapiensWorkspace" {save:callback $ \_ -> workspaceSave $> null}
  viewport <- q "#conversation-body"
  on viewport "scroll" false \_ -> unless (boolean $ document .! "hidden") do
    void chatPosition
    read "scrollSaveTimer" >>= cancelTimer
    delay 100 saveLocal >>= write "scrollSaveTimer"
  for_ ["pointerdown", "touchstart", "wheel", "keydown"] \event -> on viewport event false $ const $ write "pendingChatPosition" null *> write "lastChatGeometry" null
  on window "pagehide" false $ const suspend
  on window "pageshow" false $ const resume
  on document "visibilitychange" false \_ -> if boolean (document .! "hidden") then suspend else resume
  when (boolean connections) $ void $ call connections "subscribe" [callback \args -> do
    let snapshot = at 0 args
    read "saveTimer" >>= cancelTimer
    live <- read "live"
    write "online" $ connections .! "connected"
    if same (snapshot .! "corpora" .! "id") (live .! "corpora" .! "id") then do
      fire "applySnapshot" [snapshot]
      for_ ["renderSidebar", "renderConversation", "renderTabs", "renderWorkspace", "renderGlobal"] \name -> fire name []
    else do
      write "pendingChatPosition" $ snapshot .! "preferences" .! "chatPosition"
      write "lastChatPosition" $ snapshot .! "preferences" .! "chatPosition"
      current <- exec "makeInitialState" [snapshot]
      write "state" current
      write "live" snapshot
      write "workspaceRevision" $ snapshot .! "preferences" .! "workspace_revision" <||> value 0
      write "workspaceOwner" $ current .! "selected"
      write "renderedConversation" ""
      write "search" ""
      prop "#agent-search" "value" ""
      drafts <- read "attachmentDrafts"
      for_ (keys drafts) $ remove drafts
      for_ (keys $ snapshot .! "attachment_drafts") \key -> set drafts key $ snapshot .! "attachment_drafts" .! key
      prop "#message-input" "value" $ field (field "selected" current) $ current .! "drafts"
      fire "applySnapshot" [snapshot]
      stringify <$> preferences >>= write "savedPreferences"
      fire "render" []
      finite <- call (global .! "Number") "isFinite" [snapshot .! "preferences" .! "scroll"]
      when (not (boolean $ snapshot .! "preferences" .! "chatPosition") && boolean finite) $ prop "#conversation-body" "scrollTop" $ snapshot .! "preferences" .! "scroll"
      save
    pure null]
  fire "applySnapshot" [bootstrap]
  stringify <$> preferences >>= write "savedPreferences"
  fire "render" []
  finite <- call (global .! "Number") "isFinite" [bootstrap .! "preferences" .! "scroll"]
  when (not (boolean $ bootstrap .! "preferences" .! "chatPosition") && boolean finite) do
    prop "#conversation-body" "scrollTop" $ bootstrap .! "preferences" .! "scroll"
    save
  void $ delay 750 poll

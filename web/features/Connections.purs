module Sapiens.Corpora where

import Prelude hiding (append, join)
import Control.Parallel (parTraverse_)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Aff (Aff, try, launchAff_, delay, Milliseconds(..))
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Effect.Exception as Exception
import Sapiens.Runtime hiding (delay)
import Sapiens.Runtime as R
import Sapiens.Text as T

state :: Effect Value
state = read "connectionsState"

readStore :: String -> Value -> Effect Value
readStore key fallback = do
  result <- Exception.try do
    raw <- call (global .! "localStorage") "getItem" [value key]
    if same raw null then pure fallback else parseE (string raw) <#> \decoded -> if same decoded null then fallback else decoded
  pure $ case result of
    Left _ -> fallback
    Right found -> found

writeStore :: String -> Value -> Effect Unit
writeStore key content = do
  let storage = global .! "localStorage"
      writeValue = void $ call storage "setItem" [value key,value $ stringify content]
  first <- Exception.try writeValue
  case first of
    Right _ -> pure unit
    Left _ | T.test "^s4\\.snapshot\\." "" key -> pure unit
    Left _ -> do
      retry <- Exception.try do
        for_ (A.filter (T.test "^s4\\.snapshot\\." "") $ keys storage) \entry -> void $ call storage "removeItem" [value entry]
        writeValue
      case retry of
        Right _ -> pure unit
        Left _ -> do
          feedback <- q "#corpora-startup-feedback"
          when (boolean feedback) $ setField feedback "textContent" "Device storage is unavailable. Keep this window open to retain your draft."

json :: String -> String -> Value -> Aff Value
json path method body = do
  timeout <- liftEffect $ call (global .! "AbortSignal") "timeout" [value 20000]
  response <- await $ call global "fetch" [value path,merge [value {method,headers:value {"Content-Type":"application/json","X-Sapiens-Local":"1"},signal:timeout},if same body null then value {} else value {body:stringify body}]]
  result <- await $ call response "json" []
  unless (boolean $ response .! "ok") $ liftEffect $ throw $ string $ result .! "error" <||> value "Request failed"
  pure result

client :: Value -> Effect Value
client record = do
  s <- state
  let key = field "key" record
  unless (has key $ s .! "sessions") $ throw "Connecting…"
  unless (has key $ s .! "clients") do
    transport <- construct (global .! "window" .! "RemoteTransport") [s .! "sessions" .! key]
    set (s .! "clients") key transport
  pure $ s .! "clients" .! key

request :: Value -> String -> String -> Value -> Aff Value
request record path method body = do
  s <- liftEffect state
  unless (boolean record) $ liftEffect $ throw "Connect a corpora first."
  when (same record (s .! "active") && not (boolean $ s .! "connected") && method /= "GET") $ liftEffect $ throw "Offline — read only."
  if boolean (s .! "remote") then do
    transport <- liftEffect $ client record
    response <- await $ call transport "fetch" [value path,merge [value {method},if same body null then value {} else value {body:stringify body}]]
    result <- await $ call response "json" []
    unless (boolean $ response .! "ok") $ liftEffect $ throw $ string $ result .! "error" <||> value "Request failed"
    pure result
  else json ("/api/host/corpora/" <> field "id" record <> path) method body

renderRows :: Effect Unit
renderRows = do
  s <- state
  archived <- q "#corpora-archived"
  menu <- q "#corpora-menu"
  statusMenu <- q "#corpora-status-menu"
  let records = items "records" s
      active = s .! "active"
      busy = boolean $ s .! "busy"
      hasLocal = not (boolean $ s .! "remote") && A.any (\r -> field "location" r == "Local") records
      disabled = if busy then "disabled" else ""
      stateName r = (value {active:"Active",paused:"Paused",archived:"Archived"}) .! field "status" r <||> value "Active"
      rows = stringMap (A.filter (\r -> not (boolean $ r .! "archived") && field "status" r /= "archived" || boolean (archived .! "checked")) records) \r ->
        "<div class=\"corpora-record\" data-selected=\"" <> show (same (r .! "key") (active .! "key")) <> "\"><span class=\"corpora-location-cell\">" <> escape (field "location" r) <>
        "</span><span class=\"corpora-name-cell\"><button class=\"corpora-name\" data-enter=\"" <> escape (field "key" r) <> "\" " <> (if field "status" r == "archived" || busy then "disabled" else "") <> " aria-pressed=\"" <> show (same (r .! "key") (active .! "key")) <> "\">" <> escape (field "name" r) <>
        "</button><button class=\"corpora-edit\" data-edit=\"" <> escape (field "key" r) <> "\" " <> disabled <> ">Edit</button></span><span class=\"corpora-state\"><i class=\"corpora-dot\" data-active=\"" <> show (field "status" r == "active" && (not (same r active) || boolean (s .! "connected"))) <> "\"></i>" <>
        escape (if same r active && not (boolean $ s .! "connected") then "Offline" else string $ stateName r) <> "</span><span class=\"corpora-device\">" <> escape (string $ r .! "device" <||> value "Host computer") <> "</span>" <>
        (if hasLocal then "<span class=\"corpora-pairing-cell\">" <> (if field "location" r /= "Local" then "" else "<button data-pairing=\"" <> escape (field "key" r) <> "\" " <> disabled <> ">" <> (if boolean (r .! "paired") then "Edit Pairing" else "New Pairing") <> "</button>") <> "</span>" else "") <> "</div>"
  setField (menu .! "dataset") "hasLocal" $ show hasLocal
  qIn menu ".corpora-remote-column" >>= \node -> setField node "hidden" $ not hasLocal
  host <- q "#corpora-rows"
  when (field "rendered" (host .! "dataset") /= rows) $ html host rows *> setField (host .! "dataset") "rendered" rows
  prop "#create-local-corpora" "hidden" $ not $ boolean $ s .! "localAvailable"
  prop "#manage-relay-servers" "hidden" $ boolean $ s .! "remote"
  prop "#corpora-picker" "title" $ string $ active .! "name" <||> value "Corpora"
  q "#corpora-picker" >>= \node -> attr node "aria-expanded" $ show $ not $ boolean $ menu .! "hidden"
  q "#connection-status" >>= \node -> attr node "aria-expanded" $ show $ not $ boolean $ statusMenu .! "hidden"

renderStatus :: Effect Unit
renderStatus = do
  s <- state
  let active = s .! "active"
      busy = boolean $ s .! "busy"
      connected = boolean $ s .! "connected"
      statusName = string $ (value {active:"Active",paused:"Paused",archived:"Archived"}) .! field "status" active <||> value "Active"
  prop "#corpora-location" "textContent" $ string $ active .! "location" <||> value "Remote"
  prop "#connection-label" "textContent" $ if busy then "Connecting…" else if not (boolean active) then "Not connected" else if not connected then "Offline" else if boolean (active .! "stopping") then "Pausing…" else statusName
  node <- q "#connection-status"
  setField (node .! "dataset") "online" $ show $ connected && not busy && field "status" active == "active"
  setField node "disabled" $ not (boolean active) || not connected || busy
  menu <- q "#corpora-status-menu"
  attr node "aria-expanded" $ show $ not $ boolean $ menu .! "hidden"
  html menu $ if field "status" active == "archived" then "<span>Archived</span>" else
    "<button type=\"button\" data-lifecycle=\"pause\" " <> (if field "status" active == "paused" then "disabled>Paused ✓" else ">Pause") <> "</button><button type=\"button\" data-lifecycle=\"activate\" " <> (if field "status" active == "active" then "disabled>Active ✓" else ">Activate") <> "</button>"
  renderRows
  event <- construct (global .! "Event") [value "sapiens-connection-change"]
  void $ call (global .! "window") "dispatchEvent" [event]

metadata :: Value -> Value -> Effect Unit
metadata record data_ = do
  void $ call (global .! "Object") "assign" [record,data_]
  s <- state
  when (same record $ s .! "active") renderStatus
  renderRows

notice :: String -> Effect Unit
notice text = prop "#corpora-notice-text" "textContent" text *> (q "#corpora-notice" >>= \node -> void $ call node "showModal" [])

cleanup :: Effect Unit
cleanup = do
  s <- state
  when (boolean $ s .! "formCleanup") $ void $ invoke (s .! "formCleanup") []
  set s "formCleanup" null

showForm :: String -> String -> Effect Unit
showForm title source = do
  cleanup
  prop "#corpora-dialog-title" "textContent" title
  putHTML "#corpora-dialog-body" source
  dialog <- q "#corpora-dialog"
  unless (boolean $ dialog .! "open") do
    void $ call dialog "showModal" []
    void $ call (global .! "history") "pushState" [value {sapiensDialog:true},value ""]

closeForm :: Effect Unit
closeForm = do
  cleanup
  q "#corpora-dialog" >>= \node -> void $ call node "close" []
  when (boolean $ global .! "history" .! "state" .! "sapiensDialog") do
    s <- state
    setField s "suppressDialogPop" true
    void $ call (global .! "history") "back" []

cache :: Value -> Effect Unit
cache snapshot = do
  s <- state
  let active = s .! "active"
  when (boolean active && same (snapshot .! "corpora" .! "id") (active .! "id")) $ void $ Exception.try do
    let turns = items "turns" snapshot
        recent = merge [snapshot,value {turns:A.drop (max 0 $ A.length turns - 100) turns,events:[] :: Array Value,pulses:[] :: Array Value}]
    when (int ((value $ stringify recent) .! "length") > 750000) do
      setField recent "turns" ([] :: Array Value)
      setField recent "groups" $ map (\group -> let messages = items "messages" group in merge [group,value {messages:A.drop (max 0 $ A.length messages - 10) messages}]) $ items "groups" recent
    let key = "s4.snapshot." <> field "key" active
        snapshots = A.filter (\k -> T.test "^s4\\.snapshot\\." "" k && k /= key) $ keys $ global .! "localStorage"
    for_ (A.take (max 0 $ A.length snapshots - 2) snapshots) \k -> void $ call (global .! "localStorage") "removeItem" [value k]
    writeStore key recent

decorate :: Value -> Value -> Effect Value
decorate snapshot key_ = do
  s <- state
  local <- readStore ("s4.workspace." <> string (key_ <||> s .! "active" .! "key")) null
  pure $ if not (boolean local) then snapshot else merge [snapshot,value {preferences:merge [snapshot .! "preferences",local,value {workspaces:snapshot .! "preferences" .! "workspaces" <||> local .! "workspaces" <||> value {}}]}]

deliver :: Value -> Effect Unit
deliver snapshot = do
  s <- state
  decorated <- decorate snapshot null
  set s "lastSnapshot" decorated
  if not (boolean $ s .! "started") then setField s "started" true *> void (invoke (s .! "initialResolve") [decorated])
  else when (boolean $ s .! "listener") $ void $ invoke (s .! "listener") [decorated]

lifecycle :: Value -> String -> Aff Value
lifecycle record action = do
  initial <- request record "/api/corpora" "GET" null
  liftEffect $ metadata record initial
  operation <- liftEffect $ call (global .! "crypto") "randomUUID" []
  let data_ = value {action,revision:initial .! "revision",operation}
  liftEffect do
    time <- now
    writeStore "s4.lifecycle.pending" $ merge [value {key:record .! "key",expiresAt:time + 30000.0},data_]
  result <- try $ request record "/api/corpora/lifecycle" "PUT" data_
  info <- case result of
    Right found -> pure found
    Left error -> do
      liftEffect $ state >>= \s -> setField s "connected" false *> renderStatus
      liftEffect $ Exception.throwException error
  liftEffect $ metadata record info
  let wait attempt current = if attempt >= 10 || not (boolean $ current .! "stopping") then pure current else do
        delay $ Milliseconds 500.0
        next <- request record "/api/corpora" "GET" null
        liftEffect $ metadata record next
        wait (attempt + 1) next
  final <- wait 0 info
  when (boolean $ final .! "stopping") $ liftEffect $ throw "Work is still stopping. Try again shortly."
  liftEffect $ writeStore "s4.lifecycle.pending" null
  pure final

reconcile :: Aff Unit
reconcile = do
  s <- liftEffect state
  pending <- liftEffect $ readStore "s4.lifecycle.pending" null
  when (boolean pending) do
    let record = find (\r -> same (r .! "key") (pending .! "key")) $ items "records" s
    unless (boolean record) $ liftEffect $ throw "The previous switch needs its original connection."
    outcome <- request record ("/api/corpora/operations/" <> T.encode (field "operation" pending)) "GET" null
    let info = outcome .! "corpora"
    liftEffect $ metadata record info
    when (boolean $ info .! "stopping") $ liftEffect $ throw "Work is still stopping. Try again shortly."
    time <- liftEffect now
    when (not (boolean $ outcome .! "applied") && time < number (pending .! "expiresAt")) $ liftEffect $ throw "The previous switch is still being confirmed. Try again shortly."
    liftEffect $ writeStore "s4.lifecycle.pending" null
    when (boolean (outcome .! "applied") && field "action" pending == "activate" && not (same (record .! "key") (s .! "active" .! "key")) && field "status" info == "active") $ void $ lifecycle record "pause"
  switching <- liftEffect $ readStore "s4.switch.pending" null
  when (field "phase" switching == "activating" && not (same (switching .! "to") (s .! "active" .! "key"))) do
    let target = find (\r -> same (r .! "key") (switching .! "to")) $ items "records" s
    unless (boolean target) $ liftEffect $ throw "The previous switch needs its original connection."
    request target "/api/corpora" "GET" null >>= liftEffect <<< metadata target
    when (field "status" target == "active") $ void $ lifecycle target "pause"
  liftEffect $ writeStore "s4.switch.pending" null

enter :: Value -> Aff Unit
enter record = do
  s <- liftEffect state
  unless (boolean (s .! "busy") || field "status" record == "archived") do
    if same (record .! "key") (s .! "active" .! "key") then liftEffect $ prop "#corpora-menu" "hidden" false
    else do
      liftEffect $ setField s "busy" true *> setField s "generation" (int (s .! "generation") + 1) *> renderStatus *> renderRows
      result <- try do
        cached <- liftEffect $ readStore ("s4.snapshot." <> field "key" record) null
        snapshot <- if boolean cached then pure cached else request record "/api/state" "GET" null
        liftEffect do
          metadata record $ snapshot .! "corpora"
          let workspace = global .! "window" .! "sapiensWorkspace"
          when (boolean workspace) $ void $ call workspace "save" []
          set s "active" record
          writeStore "s4.active" $ record .! "key"
          setField s "connected" $ not $ boolean cached
          cache snapshot
          deliver snapshot
          prop "#corpora-menu" "hidden" false
          prop "#corpora-empty" "hidden" true
          writeStore "s4.records" $ s .! "records"
      liftEffect do
        case result of
          Left error -> notice $ message error
          Right _ -> pure unit
        setField s "busy" false
        renderRows
        renderStatus

refreshPairings :: Effect Unit
refreshPairings = launchAff_ do
  s <- liftEffect state
  parTraverse_ (\record -> do
    result <- try $ request record "/api/remote" "GET" null
    case result of
      Left _ -> pure unit
      Right data_ -> liftEffect $ set record "paired" (data_ .! "paired") *> renderRows) $ A.filter (\r -> not (boolean $ s .! "remote") && field "location" r == "Local") $ items "records" s

restore :: Effect Unit
restore = defer \_ -> launchAff_ restoreAff

restoreAff :: Aff Unit
restoreAff = do
  s <- liftEffect state
  result <- try do
    if boolean (s .! "remote") then do
      saved <- await $ call (global .! "window" .! "RemoteSession") "list" []
      liftEffect do
        setField s "sessions" {}
        for_ (A.filter (\session -> same (session .! "relay") (global .! "location" .! "origin")) $ array saved) \session -> do
          key <- call (global .! "window" .! "RemoteSession") "key" [session]
          set (s .! "sessions") (string key) session
        setField s "records" $ map (\key -> merge [s .! "sessions" .! key .! "corpora",value {key,location:"Remote"}]) $ keys $ s .! "sessions"
    else do
      data_ <- json "/api/host" "GET" null
      liftEffect do
        set s "localAvailable" $ data_ .! "local_available"
        setField s "records" $ map (\r -> merge [r,value {key:r .! "id"}]) $ items "corpora" data_
    liftEffect do
      writeStore "s4.records" $ s .! "records"
      if not (boolean $ s .! "active") then do
        saved <- readStore "s4.active" null
        set s "active" $ find (\r -> same (r .! "key") saved) (items "records" s) <||> at 0 (items "records" s)
      else set s "active" $ find (\r -> same (r .! "key") (s .! "active" .! "key")) $ items "records" s
      search <- construct (global .! "URLSearchParams") [global .! "location" .! "search"]
      pairing <- call search "get" [value "pairing"]
      when (not (boolean $ s .! "remote") && string pairing == "local") do
        void $ call (global .! "history") "replaceState" [null,value "",global .! "location" .! "pathname"]
        fire "remoteControl" [find (\r -> field "location" r == "Local") $ items "records" s]
      prop "#empty-create-corpora" "hidden" $ not $ boolean $ s .! "localAvailable"
      prop "#corpora-empty" "hidden" $ boolean $ s .! "active"
      renderRows
      renderStatus
    when (boolean $ s .! "active") do
      liftEffect $ writeStore "s4.active" $ s .! "active" .! "key"
      cached <- liftEffect $ readStore ("s4.snapshot." <> field "key" (s .! "active")) null
      when (not (boolean $ s .! "started") && boolean cached) $ liftEffect $ deliver cached
      let record = s .! "active"
          version = s .! "generation"
      when (boolean $ s .! "remote") $ void $ await $ client record >>= \transport -> call transport "authenticate" []
      snapshot <- request record "/api/state" "GET" null
      when (same record (s .! "active") && same version (s .! "generation")) $ liftEffect do
        metadata record $ snapshot .! "corpora"
        setField s "connected" true
        prop "#corpora-startup-feedback" "textContent" ""
        cache snapshot
        deliver snapshot
        renderStatus
  case result of
    Left error -> liftEffect do
      prop "#corpora-startup-feedback" "textContent" $ message error
      renderStatus
      unless (boolean $ s .! "started") $ void $ R.delay 3000 restore
    Right _ -> pure unit

start :: Effect Unit
start = do
  s <- state
  let installer = global .! "window" .! "RemoteInstall"
      worker = global .! "navigator" .! "serviceWorker"
  when (boolean (s .! "remote") && boolean worker) $ launchAff_ $ void $ try $ await $ call worker "register" [value "/sw.js"]
  installed <- call installer "installed" []
  if boolean (s .! "remote") && boolean (installer .! "mobile") && not (boolean installed) then do
    setField s "installRequired" true
    prop "#mobile-install-gate" "hidden" false
    prop "#corpora-empty" "hidden" true
    void $ call installer "mount" []
  else do
    setField s "installRequired" false
    prop "#mobile-install-gate" "hidden" true
    records <- readStore "s4.records" $ value ([] :: Array Value)
    set s "records" records
    selected <- readStore "s4.active" null
    let active = find (\r -> same (r .! "key") selected) $ array records
    set s "active" active
    when (boolean active) do
      cached <- readStore ("s4.snapshot." <> field "key" active) null
      when (boolean cached) $ deliver cached
    renderRows
    renderStatus
    restore

initialize :: Effect Unit
initialize = do
  remote <- call (global .! "document" .! "body") "hasAttribute" [value "data-remote"]
  let s = value {records:[] :: Array Value,sessions:value {},clients:value {},active:null,connected:false,busy:false,localAvailable:false,started:false,generation:0,lastSnapshot:null,listener:null,formCleanup:null,installRequired:false,suppressDialogPop:false,remote}
  write "connectionsState" s
  initial <- promise \resolve _ -> set s "initialResolve" resolve
  let api_ = value {initial,remote}
  for_ ["active","connected","busy","generation"] \name -> getter api_ name $ state <#> flip get name
  set api_ "subscribe" $ callback \args -> do
    set s "listener" $ at 0 args
    when (boolean $ s .! "lastSnapshot") $ void $ invoke (at 0 args) [s .! "lastSnapshot"]
    pure null
  set api_ "fetch" $ async \args -> do
    let record = s .! "active"
        path = string $ at 0 args
        options = at 1 args <||> value {}
    when (not (boolean record) || boolean (s .! "busy")) $ liftEffect $ throw "Connecting…"
    method <- liftEffect $ call (options .! "method" <||> value "GET") "toUpperCase" []
    when (not (boolean $ s .! "connected") && not (A.elem (string method) ["GET","HEAD"])) $ liftEffect $ throw "Offline — read only."
    response <- await $ if boolean remote then client record >>= \transport -> call transport "fetch" [value path,options] else call global "fetch" [value $ "/api/host/corpora/" <> field "id" record <> path,options]
    unless (same record $ s .! "active") $ liftEffect $ throw "Workspace changed"
    pure response
  set api_ "snapshot" $ callback \args -> do
    let snapshot = at 0 args
    when (same (snapshot .! "corpora" .! "id") (s .! "active" .! "id")) do
      prop "#corpora-startup-feedback" "textContent" ""
      metadata (s .! "active") $ snapshot .! "corpora"
      setField s "connected" true
      cache snapshot
      renderStatus
    pure null
  set api_ "offline" $ callback \args -> do
    setField s "connected" false
    let error = at 0 args
    when (boolean (error .! "revoked") || T.test "revoked|another window" "" (field "message" error)) $ prop "#corpora-startup-feedback" "textContent" $ field "message" error
    renderStatus
    pure null
  set api_ "save" $ callback \args -> when (boolean $ s .! "active") (writeStore ("s4.workspace." <> field "key" (s .! "active")) (at 0 args)) $> null
  set api_ "decorate" $ callback \args -> decorate (at 0 args) (at 1 args)
  set api_ "remoteControl" $ callback $ exec "remoteControl"
  set api_ "connectForm" $ callback $ exec "connectForm"
  set (global .! "window") "SapiensConnections" api_

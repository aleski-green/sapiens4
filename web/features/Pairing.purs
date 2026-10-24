module Sapiens.Pairing (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.String as S
import Effect (Effect)
import Effect.Aff (Aff, try, launchAff_, delay, Milliseconds(..))
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Effect.Exception as Exception
import Sapiens.Corpora as C
import Sapiens.Runtime hiding (delay)
import Sapiens.Runtime as R
import Sapiens.Text as T

resetRelays :: Boolean -> Aff Unit
resetRelays broadcast = do
  liftEffect do
    s <- C.state
    setField s "generation" $ int (s .! "generation") + 1
    for_ (A.filter (\r -> field "location" r == "Remote") $ items "records" s) \row -> do
      let key = field "key" row
      when (boolean $ s .! "clients" .! key) $ void $ call (s .! "clients" .! key) "close" []
      remove (s .! "clients") key
      remove (s .! "sessions") key
      void $ call (global .! "localStorage") "removeItem" [value $ "s4.snapshot." <> key]
    setField s "records" $ A.filter (\r -> field "location" r == "Local") $ items "records" s
    for_ (items "records" s) \row -> setField row "paired" false
    when (field "location" (s .! "active") == "Remote") do
      set s "active" $ at 0 $ items "records" s
      set s "lastSnapshot" null
      setField s "connected" false
      C.writeStore "s4.active" $ s .! "active" .! "key"
    C.writeStore "s4.records" $ s .! "records"
    C.writeStore "s4.lifecycle.pending" null
    C.writeStore "s4.switch.pending" null
    when broadcast $ call (global .! "crypto") "randomUUID" [] >>= C.writeStore "s4.relay-reset"
  C.restoreAff

relayManager :: Value -> Effect Unit
relayManager record = do
  s <- C.state
  unless (boolean (s .! "remote") || boolean (s .! "busy")) $ void $ call (global .! "window" .! "RelayServers") "mount" [value
    {show:callback \args -> C.showForm (string $ at 0 args) (string $ at 1 args) $> null
    ,json:async \args -> C.json (string $ at 0 args) (string $ at 1 args <||> value "GET") (at 2 args)
    ,reset:async \_ -> resetRelays true $> null,pairing:boolean record
    ,done:callback \_ -> (if boolean record then fire "remoteControl" [record,value true] else C.closeForm) $> null
    ,cleanup:callback \args -> set s "formCleanup" (at 0 args) $> null}]

edit :: Value -> Effect Unit
edit record = do
  C.showForm "Message to ChiefSapi" "<form id=\"chief-settings-form\"><textarea name=\"message\" aria-label=\"Message to ChiefSapi\" rows=\"8\" required></textarea><p class=\"corpora-feedback\" role=\"status\"></p><button type=\"submit\">Send to ChiefSapi ↑</button></form>"
  form <- q "#chief-settings-form"
  s <- C.state
  let template = string $ record .! "settings_template" <||> s .! "lastSnapshot" .! "corpora" .! "settings_template"
      fill text key = S.replaceAll (S.Pattern $ "{" <> key <> "}") (S.Replacement $ field key record) text
  setField (form .! "elements" .! "message") "value" $ fill (fill (fill template "name") "device") "scope"
  on form "submit" false \event -> do
    prevent event
    unless (boolean $ s .! "busy") do
      button <- qIn form "button"
      feedback <- qIn form "[role=status]"
      setField button "disabled" true
      setField s "busy" true
      setField s "generation" $ int (s .! "generation") + 1
      C.renderStatus
      C.renderRows
      launchAff_ do
        result <- try do
          C.reconcile
          initial <- C.request record "/api/corpora" "GET" null
          liftEffect $ C.metadata record initial
          when (field "status" initial == "archived") $ liftEffect $ throw "Restore this archived corpora before sending. Your draft is kept here."
          info <- if field "status" initial == "paused" then liftEffect (setField feedback "textContent" "Activating corpora…") *> C.lifecycle record "activate" else pure initial
          liftEffect $ setField feedback "textContent" "Sending to ChiefSapi…"
          void $ C.request record ("/api/agents/" <> field "chief_id" info <> "/messages") "POST" $ value {text:form .! "elements" .! "message" .! "value"}
          liftEffect C.closeForm
        liftEffect do
          case result of
            Left error -> setField feedback "textContent" $ message error
            Right _ -> pure unit
          setField button "disabled" false
          setField s "busy" false
          C.renderRows
          C.renderStatus
  focus $ form .! "elements" .! "message"

createLocal :: Effect Unit
createLocal = do
  C.showForm "Create local corpora" "<form id=\"new-corpora-form\"><label>Corpora name<input name=\"name\" required maxlength=\"200\" autofocus></label><label>Scope of work<textarea name=\"scope\" rows=\"4\" maxlength=\"16000\"></textarea></label><p role=\"status\"></p><button type=\"submit\">Create</button></form>"
  form <- q "#new-corpora-form"
  on form "submit" false \event -> do
    prevent event
    button <- qIn form "button"
    setField button "disabled" true
    launchAff_ do
      result <- try do
        record <- C.json "/api/host/local" "POST" $ value {name:form .! "elements" .! "name" .! "value",scope:form .! "elements" .! "scope" .! "value"}
        liftEffect do
          set record "key" $ record .! "id"
          s <- C.state
          setField s "records" $ A.snoc (items "records" s) record
          C.renderRows
          C.closeForm
        C.enter record
      case result of
        Left error -> liftEffect do
          qIn form "[role=status]" >>= \node -> setField node "textContent" $ message error
          setField button "disabled" false
        Right _ -> pure unit

connectForm :: Effect Unit
connectForm = do
  s <- C.state
  if boolean (s .! "installRequired") then void $ call (global .! "window" .! "RemoteInstall") "mount" []
  else do
    C.showForm "Connect remote corpora" "<p>On the host, open the corpora menu and choose <strong>New Pairing</strong> in its Remote column.</p><section id=\"pair-panel\"><div id=\"qr-step\"><button id=\"scan-qr\" type=\"button\">Scan QR</button><label class=\"qr-upload\">Upload QR<input id=\"qr-file\" type=\"file\" accept=\"image/png,image/jpeg,image/webp\"></label></div><div id=\"scanner\" hidden><video id=\"qr-camera\" autoplay playsinline muted></video><button id=\"stop-scan\" type=\"button\">Cancel scan</button></div><form id=\"paste-invitation\"><label>Or paste an invitation<textarea name=\"invitation\" rows=\"2\" required spellcheck=\"false\" autocomplete=\"off\"></textarea></label><button type=\"submit\">Connect</button></form></section><section id=\"verify-panel\" hidden><p>Approve this matching code on the host.</p><strong id=\"confirmation-code\"></strong></section><p id=\"pair-feedback\" role=\"status\"></p>"
    let local = value {cancelled:false,connecting:false,pendingClient:null,pendingID:null,scanner:null}
        feedback text = do
          node <- q "#pair-feedback"
          when (boolean node) $ setField node "textContent" text
        pair invitation = unless (boolean (local .! "cancelled") || boolean (local .! "connecting")) do
          liftEffect $ setField local "connecting" true
          result <- try do
            liftEffect do
              void $ call (local .! "scanner") "stop" []
              prop "#pair-panel" "hidden" true
              prop "#verify-panel" "hidden" false
              feedback "Waiting for host approval…"
            record <- if boolean (s .! "remote") then do
              transport <- await $ call (global .! "window" .! "RemoteTransport") "invitation" [invitation]
              liftEffect $ set local "pendingClient" transport
              encoded <- liftEffect $ call (global .! "window" .! "RemoteTransport") "b64" [transport .! "session" .! "keys" .! "publicKey"]
              code <- await $ call (global .! "window" .! "RemoteCode") "confirmation" [invitation .! "desktop",encoded,invitation .! "room"]
              liftEffect $ prop "#confirmation-code" "textContent" code
              info <- await $ call transport "authenticate" [value true]
              if boolean (local .! "cancelled") then pure null else liftEffect do
                key <- call (global .! "window" .! "RemoteSession") "key" [transport .! "session"]
                set (s .! "sessions") (string key) $ transport .! "session"
                when (boolean $ s .! "clients" .! string key) $ void $ call (s .! "clients" .! string key) "close" []
                set (s .! "clients") (string key) transport
                set local "pendingClient" null
                pure $ merge [info,value {location:"Remote",key}]
            else do
              initial <- C.json "/api/host/pair" "POST" invitation
              liftEffect $ set local "pendingID" (initial .! "id") *> prop "#confirmation-code" "textContent" (initial .! "code")
              let wait result_ = if boolean (local .! "cancelled") || field "state" result_ /= "waiting" then pure result_ else do
                    delay $ Milliseconds 1000.0
                    next <- if boolean (local .! "cancelled") then pure result_ else C.json ("/api/host/pair/" <> field "pendingID" local) "GET" null
                    wait next
              final <- wait initial
              if boolean (local .! "cancelled") then pure null else do
                when (field "state" final /= "approved") $ liftEffect $ throw $ string $ final .! "error" <||> value "Connection cancelled"
                liftEffect $ set local "pendingID" null
                pure $ merge [final .! "corpora",value {key:final .! "corpora" .! "id"}]
            when (boolean record && not (boolean $ local .! "cancelled")) do
              liftEffect do
                setField s "records" $ A.snoc (A.filter (\r -> not $ same (r .! "key") (record .! "key")) $ items "records" s) record
                C.writeStore "s4.records" $ s .! "records"
                C.renderRows
                C.closeForm
              C.enter record
          liftEffect do
            case result of
              Left error | not (boolean $ local .! "cancelled") -> feedback (message error) *> prop "#pair-panel" "hidden" false *> prop "#verify-panel" "hidden" true
              _ -> pure unit
            setField local "connecting" false
    scanner <- call (global .! "window" .! "RemoteOnboarding") "mount" [async \args -> pair (at 0 args) $> null,callback \args -> feedback (string $ at 0 args) $> null]
    set local "scanner" scanner
    q "#paste-invitation" >>= \form -> on form "submit" false \event -> do
      prevent event
      launchAff_ do
        result <- try do
          invitation <- liftEffect $ call (global .! "window" .! "RemoteCode") "decode" [event .! "target" .! "elements" .! "invitation" .! "value"]
          pair invitation
        case result of
          Left error -> liftEffect $ feedback $ message error
          Right _ -> pure unit
    set s "formCleanup" $ callback \_ -> do
      setField local "cancelled" true
      void $ call scanner "dispose" []
      when (boolean $ local .! "pendingClient") $ void $ call (local .! "pendingClient") "close" []
      when (boolean $ local .! "pendingID") $ launchAff_ $ void $ try $ C.json ("/api/host/pair/" <> field "pendingID" local) "POST" $ value {}
      pure null

remoteControl :: Value -> Boolean -> Aff Unit
remoteControl record ready = do
  s <- liftEffect C.state
  unless (boolean (s .! "remote") || field "location" record /= "Local") do
    proceed <- if ready then pure true else do
      result <- try $ C.request record "/api/remote" "GET" null
      case result of
        Left error -> liftEffect (C.notice $ message error) $> false
        Right data_ | not (boolean (data_ .! "enabled") || boolean (data_ .! "paired")) -> liftEffect (relayManager record) $> false
        Right _ -> pure true
    when proceed $ liftEffect $ hostPairing record

hostPairing :: Value -> Effect Unit
hostPairing record = do
  C.showForm (if boolean (record .! "paired") then "Edit Pairing" else "New Pairing") "<div id=\"remote-host-content\"></div><p id=\"remote-host-feedback\" role=\"status\"></p>"
  container <- q "#remote-host-content"
  let local = value {cancelled:false,timer:null,invitationLink:""}
      status text = unless (boolean $ local .! "cancelled") $ prop "#remote-host-feedback" "textContent" text
      date_ input = do
        finite <- call (global .! "Number") "isFinite" [input]
        if kind input /= "number" || not (boolean finite) then pure "Not recorded" else do
          d <- construct (global .! "Date") [value $ number input * 1000.0]
          string <$> call d "toLocaleString" [value ([] :: Array Value),value {dateStyle:"medium",timeStyle:"long"}]
      refresh = do
        result <- try do
          data_ <- C.request record "/api/remote" "GET" null
          unless (boolean $ local .! "cancelled") do
            time <- liftEffect now
            let info = data_ .! "device_info"
                invitation = if boolean (data_ .! "enabled") && number (data_ .! "invitation" .! "expires") > time / 1000.0 then data_ .! "invitation" else null
            liftEffect do
              set record "paired" $ data_ .! "paired"
              C.renderRows
              prop "#corpora-dialog-title" "textContent" $ if boolean (data_ .! "paired") then "Edit Pairing" else "New Pairing"
              link <- if boolean invitation then call (global .! "window" .! "RemoteCode") "link" [invitation] else pure $ value ""
              set local "invitationLink" link
            source <- if same (data_ .! "available") (value false) then pure "<p>Remote control is unavailable. Install the remote dependencies and restart Sapiens4.</p>"
              else if boolean (data_ .! "paired") then do
                paired <- liftEffect $ date_ $ data_ .! "paired_at"
                connected <- liftEffect $ date_ $ data_ .! "last_connected_at"
                let deviceInfo = S.joinWith " · " $ A.filter (_ /= "") [field "platform" info,field "client" info]
                pure $ "<p class=\"pairing-corpora\">" <> escape (field "name" record) <> "</p><dl class=\"pairing-details\"><dt>Device</dt><dd>" <> escape (string $ info .! "name" <||> value "Not recorded") <> "</dd><dt>Device info</dt><dd>" <> escape (if deviceInfo == "" then "Not recorded" else deviceInfo) <> "</dd><dt>Paired</dt><dd>" <> escape paired <> "</dd><dt>Last connected</dt><dd>" <> escape connected <> "</dd></dl><div class=\"pairing-actions\"><button data-remote-action=\"replace\">Replace remote</button><button data-remote-action=\"revoke\">Revoke remote</button></div>"
              else if boolean (data_ .! "pending") then pure $ "<p>Approve only if this code matches your remote device.</p><strong>" <> escape (field "confirmation_code" $ data_ .! "pending") <> "</strong><button data-remote-action=\"approve\" data-peer=\"" <> escape (field "peer" $ data_ .! "pending") <> "\" " <> (if boolean (data_ .! "pending" .! "confirmation_code") then "" else "disabled") <> ">Approve device</button>"
              else if boolean invitation then do
                expires <- liftEffect $ date_ $ invitation .! "expires"
                pure $ "<p>In the installed app, choose Connect remote corpora and scan this QR.</p><canvas id=\"host-pair-qr\"></canvas><p>Expires " <> escape expires <> "</p><div class=\"pairing-actions\"><button data-remote-action=\"link\">Show link</button><a id=\"download-pair-qr\" download=\"sapiens4-pairing.png\">Download QR</a><a href=\"" <> escape (field "relay" invitation) <> "\" target=\"_blank\" rel=\"noopener noreferrer\">Open app ↗</a><button data-remote-action=\"revoke\">Cancel invitation</button></div><input id=\"host-pair-link\" aria-label=\"Pairing link\" readonly hidden>"
              else if boolean (data_ .! "enabled") then pure "<p>Invitation expired.</p><button data-remote-action=\"revoke\">Cancel invitation</button>"
              else pure "<div class=\"pairing-actions\"><button data-remote-action=\"pair\">Show QR</button><button data-remote-action=\"servers\">Relay servers</button></div>"
            let content = source <> if boolean (data_ .! "error") then "<p>" <> escape (field "error" data_) <> "</p>" else ""
            when (field "content" (container .! "dataset") /= content) do
              liftEffect $ html container content *> setField (container .! "dataset") "content" content
              canvas <- liftEffect $ q "#host-pair-qr"
              when (boolean canvas) do
                link <- liftEffect $ call (global .! "window" .! "RemoteCode") "link" [invitation]
                void $ await $ call (global .! "window" .! "RemoteVendor" .! "QRCode") "toCanvas" [canvas,link,value {width:320,margin:3}]
                liftEffect $ when (not (boolean $ local .! "cancelled") && boolean (canvas .! "isConnected")) do
                  url <- call canvas "toDataURL" [value "image/png"]
                  prop "#download-pair-qr" "href" url
        liftEffect do
          case result of
            Left error -> status $ message error
            Right _ -> pure unit
          unless (boolean $ local .! "cancelled") do
            cancelTimer $ local .! "timer"
            R.delay 2500 (launchAff_ refresh) >>= set local "timer"
      action button perform = do
        setField button "disabled" true
        status ""
        launchAff_ do
          result <- try $ perform *> unless (boolean $ local .! "cancelled") refresh
          liftEffect do
            case result of
              Left error -> status $ message error
              Right _ -> pure unit
            when (boolean $ button .! "isConnected") $ setField button "disabled" false
  on container "click" false \event -> do
    button <- closest (event .! "target") "[data-remote-action]"
    when (boolean button && not (boolean $ button .! "disabled")) do
      let command = field "remoteAction" $ button .! "dataset"
      if command == "servers" then relayManager record
      else if command == "link" then do
        field_ <- q "#host-pair-link"
        set field_ "value" $ local .! "invitationLink"
        setField field_ "hidden" false
        focus field_
        void $ call field_ "select" []
      else do
        approved <- if command == "revoke" then call global "confirm" [value "Revoke this remote access? It will need to pair again."] else if command == "replace" then call global "confirm" [value "Replace the trusted remote device? The previous device will lose access."] else pure $ value true
        when (boolean approved) $ action button do
          when (A.elem command ["replace","revoke"]) do
            result <- C.request record "/api/remote/revoke" "POST" $ value {}
            when (same (result .! "relay_deleted") (value false)) $ liftEffect $ status "Revoked locally. Relay could not be reached."
          when (A.elem command ["replace","pair","local"]) $ void $ C.request record "/api/remote/pair" "POST" $ if command == "local" then value {local:true} else value {saved:true}
          when (command == "approve") $ void $ C.request record "/api/remote/approve" "POST" $ value {peer:button .! "dataset" .! "peer"}
  s <- C.state
  set s "formCleanup" $ callback \_ -> setField local "cancelled" true *> cancelTimer (local .! "timer") $> null
  launchAff_ refresh

main :: Effect Unit
main = do
  register "connectForm" \_ -> connectForm $> null
  registerAsync "remoteControl" \args -> remoteControl (at 0 args) (boolean $ at 1 args) $> null
  register "corporaEdit" \args -> edit (at 0 args) $> null
  registerAsync "resetRelayConnections" \args -> resetRelays (if same (at 0 args) null then true else boolean $ at 0 args) $> null
  q "#create-local-corpora" >>= \node -> on node "click" false $ const createLocal
  q "#empty-create-corpora" >>= \node -> on node "click" false $ const createLocal
  for_ ["#connect-remote-corpora", "#empty-connect-corpora"] \selector -> q selector >>= \node -> on node "click" false $ const connectForm
  q "#manage-relay-servers" >>= \node -> on node "click" false $ const $ relayManager null
  on (global .! "window") "storage" false \event -> do
    s <- C.state
    when (not (boolean $ s .! "remote") && field "key" event == "s4.relay-reset") $ C.closeForm *> launchAff_ (resetRelays false)

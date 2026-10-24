module Sapiens.Relays (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, try, launchAff_)
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Effect.Exception as Exception
import Sapiens.Runtime
import Sapiens.Text as T

parseConnection :: String -> Effect Value
parseConnection raw = do
  result <- Exception.try do
    when (int ((value raw) .! "length") > 4096) $ throw "Invalid connection"
    data_ <- parseE raw
    url <- construct (global .! "URL") [data_ .! "relay"]
    unless (field "format" data_ == "sapiens-relay-connection-v1" && field "username" url == "" && field "password" url == "" && field "search" url == "" && field "hash" url == "" && field "pathname" url == "/" &&
      (field "protocol" url == "https:" || field "protocol" url == "http:" && A.elem (field "hostname" url) ["localhost","127.0.0.1","[::1]"])) $ throw "Invalid connection"
    if same (data_ .! "beta") (value true) && not (boolean $ data_ .! "token") then pure $ value {format:data_ .! "format",relay:url .! "origin",beta:true}
    else do
      unless (kind (data_ .! "token") == "string" && T.test "^[\\x21-\\x7e]{32,256}$" "" (field "token" data_)) $ throw "Invalid token"
      pure $ value {format:data_ .! "format",relay:url .! "origin",token:data_ .! "token"}
  case result of
    Left _ -> throw "Enter valid relay connection JSON."
    Right data_ -> pure data_

mount :: Value -> Effect Unit
mount context = do
  let local = value {state:null,archived:false,closed:false,working:false}
      guide = "https://github.com/aleski-green/sapiens4/blob/codex/remote-control-mvp/documentation/specs/RemoteMVP.md"
      screen title source = do
        void $ call context "show" [value title,value $ source <> "<p id=\"relay-feedback\" role=\"status\"></p>"]
        void $ call context "cleanup" [callback \_ -> setField local "closed" true $> null]
        setField local "closed" false
        heading <- q "#corpora-dialog-title"
        setField heading "tabIndex" (-1)
        focus heading
      feedback text = unless (boolean $ local .! "closed") do
        node <- q "#relay-feedback"
        when (boolean node) $ setField node "textContent" text
      run action = unless (boolean (local .! "working") || boolean (local .! "closed")) do
        setField local "working" true
        launchAff_ do
          result <- try action
          liftEffect do
            case result of
              Left error -> feedback $ message error
              Right _ -> pure unit
            setField local "working" false
      change data_ = do
        state <- await $ call context "json" [value "/api/host/relays",value "POST",merge [value {revision:local .! "state" .! "revision"},data_]]
        liftEffect $ set local "state" state
        when (boolean $ state .! "reset") $ void $ await $ call context "reset" []
      done = when (boolean $ context .! "done") $ void $ call context "done" []
      confirmChange data_ nextName back = do
        let state = local .! "state"
            current = find (\row -> same (row .! "id") (state .! "selected")) $ items "servers" state
        screen (if field "action" data_ == "save" then "Change connection?" else "Switch server?") $
          "<dl class=\"pairing-details\"><dt>From</dt><dd>" <> escape (field "name" current) <> "</dd><dt>To</dt><dd>" <> escape nextName <> "</dd></dl><p>Switching revokes <strong>all paired devices and remote corpora connections</strong> for this local app.</p><p>Pair all devices and reconnect all remote corpora again.</p><div class=\"pairing-actions\"><button id=\"relay-cancel\">Cancel</button><button id=\"relay-confirm\">Switch &amp; revoke all</button></div>"
        q "#relay-cancel" >>= \node -> on node "click" false (const back) *> focus node
        q "#relay-confirm" >>= \node -> on node "click" false \_ -> run do
          change $ merge [data_,value {confirm_revoke:true}]
          liftEffect $ unless (boolean $ local .! "closed") list
      list = defer \_ -> unless (boolean $ local .! "closed") do
        let state = local .! "state"
            rows = A.filter (\row -> boolean (local .! "archived") || not (boolean $ row .! "archived")) $ items "servers" state
            rowHTML = stringMap rows \row ->
              "<div class=\"relay-row\" data-current=\"" <> show (same (row .! "id") (state .! "selected")) <> "\"><label><input type=\"radio\" name=\"relay-server\" value=\"" <> escape (field "id" row) <> "\" " <>
              (if same (row .! "id") (state .! "selected") then "checked " else "") <> (if boolean (row .! "archived") || not (boolean $ row .! "available") then "disabled" else "") <> "><span><strong>" <> escape (field "name" row) <> "</strong><small>" <> escape (T.replace "^https?://" "" "" $ field "address" row) <>
              "</small></span></label><span class=\"relay-badge\">" <> (if boolean (row .! "archived") then "Archived" else if not (boolean $ row .! "available") then "Inactive" else if same (row .! "id") (state .! "selected") then "Current" else "") <>
              "</span><div class=\"relay-row-actions\"><button data-edit-relay=\"" <> escape (field "id" row) <> "\">Edit</button><button data-archive-relay=\"" <> escape (field "id" row) <> "\">" <> (if boolean (row .! "archived") then "Restore" else "Archive") <> "</button></div></div>"
        screen "Remote Control Relay Servers" $ "<div id=\"relay-list\" class=\"relay-list " <> (if A.length rows >= 3 then "relay-scroll" else "") <> "\" role=\"group\" aria-label=\"Relay servers\">" <> rowHTML <>
          "</div><label class=\"relay-check\"><input id=\"relay-archived\" type=\"checkbox\" " <> (if boolean (local .! "archived") then "checked" else "") <> ">Show archived</label><button id=\"relay-add\" class=\"relay-add\">+ Add your own relay <small>Recommended</small></button><p class=\"relay-warning\">ⓘ Beta: use at your own risk. Self-host for sensitive work.</p><button id=\"relay-continue\">" <> (if boolean (context .! "pairing") then "Continue" else "Done") <> "</button>"
        q "#relay-archived" >>= \node -> on node "change" false \event -> set local "archived" (event .! "target" .! "checked") *> list
        q "#relay-add" >>= \node -> on node "click" false $ const $ editor null null
        q "#relay-list" >>= \node -> do
          on node "change" false \event -> do
            let row = find (\r -> same (r .! "id") (event .! "target" .! "value")) $ items "servers" $ local .! "state"
            when (boolean row && not (same (row .! "id") (local .! "state" .! "selected"))) $ confirmChange (value {action:"switch",id:row .! "id"}) (field "name" row) list
          on node "click" false \event -> do
            button <- closest (event .! "target") "button"
            let d = button .! "dataset"
            when (boolean $ d .! "editRelay") $ run do
              row <- await $ call context "json" [value $ "/api/host/relays/" <> field "editRelay" d]
              liftEffect $ unless (boolean $ local .! "closed") $ editor row null
            when (boolean $ d .! "archiveRelay") $ run do
              let row = find (\r -> same (r .! "id") (d .! "archiveRelay")) $ items "servers" $ local .! "state"
              change $ value {action:if boolean (row .! "archived") then "restore" else "archive",id:row .! "id"}
              liftEffect $ unless (boolean $ local .! "closed") list
        q "#relay-continue" >>= \node -> on node "click" false \_ -> do
          let current = find (\row -> same (row .! "id") (local .! "state" .! "selected")) $ items "servers" $ local .! "state"
          if boolean (context .! "pairing") && boolean (current .! "beta") && not (boolean $ local .! "state" .! "beta_accepted") then terms else done
      editor row draft = do
        screen (if boolean row then "Edit relay" else "Add your own relay") $
          "<p><a href=\"" <> guide <> "\" target=\"_blank\" rel=\"noopener noreferrer\">Deploy on GitHub ↗</a></p><form id=\"relay-editor\"><label>Name<input name=\"name\" required maxlength=\"200\" autocomplete=\"off\"></label><label>Connection JSON<textarea name=\"connection\" rows=\"6\" required spellcheck=\"false\" autocomplete=\"off\" maxlength=\"4096\"></textarea></label><label class=\"qr-upload\">Import JSON<input name=\"file\" type=\"file\" accept=\"application/json,.json\"></label><p class=\"relay-private\">Stored privately on this desktop.</p><div class=\"pairing-actions\"><button type=\"button\" id=\"relay-editor-cancel\">Cancel</button><button type=\"submit\">Save</button></div></form>"
        form <- q "#relay-editor"
        let name = form .! "elements" .! "name"
            connection = form .! "elements" .! "connection"
            fileInput = form .! "elements" .! "file"
        setField name "value" $ if boolean draft then field "name" draft else field "name" row
        setField connection "value" $ if boolean draft then field "json" draft else if boolean row then pretty $ row .! "connection" else ""
        setField connection "placeholder" "Paste your relay.connection.json"
        q "#relay-editor-cancel" >>= \node -> on node "click" false $ const list
        on fileInput "change" false \_ -> run do
          let file = at 0 $ array $ fileInput .! "files"
          when (boolean file) do
            when (number (file .! "size") > 4096.0) $ liftEffect $ throw "Connection file is too large."
            raw <- await $ call file "text" []
            liftEffect do
              void $ parseConnection $ string raw
              set connection "value" raw
              feedback ""
        on form "submit" false \event -> do
          prevent event
          valid <- call form "reportValidity" []
          when (boolean valid && not (boolean $ local .! "working")) do
            let draft_ = value {name:T.replace "^\\s+|\\s+$" "g" "" $ field "value" name,json:connection .! "value"}
            parsed <- Exception.try $ parseConnection $ field "json" draft_
            case parsed of
              Left error -> feedback $ message error
              Right connection_ -> do
                let data_ = merge [value {action:"save",name:draft_ .! "name",connection:connection_},if boolean row then value {id:row .! "id"} else value {}]
                original <- if boolean row then parseConnection $ stringify $ row .! "connection" else pure null
                if boolean row && same (row .! "id") (local .! "state" .! "selected") && stringify connection_ /= stringify original then confirmChange data_ (field "name" draft_) (editor row draft_)
                else run $ change data_ *> liftEffect (unless (boolean $ local .! "closed") list)
        focus name
      terms = do
        screen "Use beta relay?" "<p>For sensitive work, use your own securely maintained relay.</p><p>Provided “as is,” without warranties. Use at your own risk.</p><p>To the extent permitted by law, authors, contributors, and operators disclaim liability for losses or damages from this service.</p><p>Non-excludable rights and liabilities remain unaffected.</p><label class=\"relay-check\"><input id=\"relay-accept\" type=\"checkbox\">I accept these beta terms.</label><div class=\"pairing-actions\"><button id=\"relay-beta-back\">Back</button><button id=\"relay-own\">Use my relay</button><button id=\"relay-beta-use\" disabled>Use beta</button></div>"
        q "#relay-beta-back" >>= \node -> on node "click" false $ const list
        q "#relay-own" >>= \node -> on node "click" false $ const $ editor null null
        q "#relay-accept" >>= \node -> on node "change" false \event -> prop "#relay-beta-use" "disabled" $ not $ boolean $ event .! "target" .! "checked"
        q "#relay-beta-use" >>= \node -> on node "click" false \_ -> run do
          change $ value {action:"accept-beta",accepted:true}
          liftEffect $ unless (boolean $ local .! "closed") done
  screen "Remote Control Relay Servers" "<p>Loading…</p>"
  run do
    state <- await $ call context "json" [value "/api/host/relays"]
    liftEffect $ set local "state" state *> unless (boolean $ local .! "closed") list

main :: Effect Unit
main = setField (global .! "window") "RelayServers" {mount:callback \args -> mount (at 0 args) $> null}

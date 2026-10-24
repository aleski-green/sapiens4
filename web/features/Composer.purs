module Sapiens.Composer (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Effect (Effect)
import Effect.Aff (Aff, try)
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Sapiens.Runtime
import Sapiens.Text as T

capital :: String -> String
capital text = S.toUpper (CU.take 1 text) <> CU.drop 1 text

attachmentLabel :: Value -> String
attachmentLabel item =
  let label = (if field "kind" item == "filepath" then "Filepath" else capital $ field "kind" item) <> " · " <> field "name" item
  in if field "kind" item == "link" then "<a class=\"attachment-item\" href=\"" <> escape (field "value" item) <> "\" target=\"_blank\" rel=\"noopener noreferrer\">" <> escape label <> " ↗</a>"
    else "<span class=\"attachment-item\" title=\"" <> escape (field "value" item) <> "\">" <> escape label <> "</span>"

renderAttachments :: Effect Unit
renderAttachments = do
  state <- read "state"
  drafts <- read "attachmentDrafts"
  putHTML "#attachment-chip" $ stringMap (items (field "selected" state) drafts) \a ->
    "<div class=\"attachment-chip\">" <> attachmentLabel a <> "<button type=\"button\" data-remove-upload=\"" <> escape (field "id" a) <> "\" aria-label=\"Remove " <> escape (field "name" a) <> "\">×</button></div>"

attachmentMenu :: Effect Unit
attachmentMenu = fire "modal" [value "Attach", value $ "<div class=\"attachment-menu\">" <> join (map (\kind -> "<button class=\"button\" data-attachment-kind=\"" <> kind <> "\">" <> capital kind <> "</button>") ["image","document","link","filepath"]) <> "</div>",value "CHAT"]

saveAttachment :: String -> Value -> Aff Unit
saveAttachment id data_ = do
  drafts <- liftEffect $ read "attachmentDrafts"
  when (A.length (items id drafts) >= 8) $ liftEffect $ throw "Attach up to 8 items per message."
  item <- request ("/api/" <> (if T.test "^group_" "" id then "groups" else "agents") <> "/" <> id <> "/attachments") "POST" data_
  liftEffect do
    setField drafts id $ A.snoc (items id drafts) item
    state <- read "state"
    when (field "selected" state == id) renderAttachments
    fire "save" []

pickAttachment :: String -> Effect Unit
pickAttachment kind = do
  state <- read "state"
  let id = field "selected" state
  if kind == "link" || kind == "filepath" then fire "modal"
    [value $ if kind == "link" then "Add link" else "Add filepath",value $
      "<form id=\"attachment-reference-form\" data-id=\"" <> escape id <> "\" data-kind=\"" <> kind <> "\" class=\"form-stack\"><label>" <> (if kind == "link" then "Link" else "Local filepath") <>
      "<input name=\"value\" type=\"" <> (if kind == "link" then "url" else "text") <> "\" placeholder=\"" <> (if kind == "link" then "https://…" else "/Users/…/file.pdf") <> "\" required maxlength=\"4096\"></label><button class=\"button primary\">Attach</button></form>",value "CHAT"]
  else do
    input <- element "input" "" ""
    setField input "type" "file"
    setField input "accept" $ if kind == "image" then "image/png,image/jpeg,image/gif,image/webp" else ".pdf,.txt,.md,.csv,.json,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.rtf,.odt"
    on input "change" false \_ -> do
      let file = at 0 $ array $ input .! "files"
      when (boolean file) do
        uploading <- int <$> read "uploading"
        write "uploading" $ uploading + 1
        fire "renderAgentHeader" []
        report do
          outcome <- try do
            when (number (file .! "size") > 10485760.0) $ liftEffect $ throw "Files must be 10 MB or smaller."
            data_ <- await do
              construct (global .! "Promise") [callback \args -> do
                let resolve = at 0 args
                    reject = at 1 args
                reader <- construct (global .! "FileReader") []
                set reader "onload" $ callback \_ -> invoke resolve [value $ fromMaybe "" $ A.index (S.split (S.Pattern ",") $ field "result" reader) 1]
                set reader "onerror" $ callback \_ -> construct (global .! "Error") [value "Could not read this file."] >>= \error -> invoke reject [error]
                call reader "readAsDataURL" [file]]
            saveAttachment id $ value {kind, name:file .! "name", data:data_}
            liftEffect $ fire "closeModal" []
          liftEffect do
            current <- int <$> read "uploading"
            write "uploading" $ current - 1
            fire "renderAgentHeader" []
            case outcome of
              Left error -> fire "toast" [value $ message error]
              Right _ -> pure unit
    void $ call input "click" []

agentSettings :: Effect Unit
agentSettings = do
  a <- exec "selected" []
  if field "kind" a == "group" then fire "groupDialog" [a] else do
    live <- read "live"
    names <- exec "nameSuggestions" []
    managers <- exec "managerOptions" [a]
    let execution = live .! "orchestration" .! field "id" a .! "execution"
        tabs = [{key:"profile",label:"Profile"},{key:"context",label:"Context"},{key:"usage",label:"Usage"},{key:"limits",label:"Limits"}]
        tabHTML = join $ A.mapWithIndex (\i tab -> "<button type=\"button\" role=\"tab\" id=\"settings-tab-" <> tab.key <> "\" aria-controls=\"settings-panel-" <> tab.key <> "\" aria-selected=\"" <> show (i == 0) <> "\" tabindex=\"" <> (if i == 0 then "0" else "-1") <> "\" " <> (if i == 0 then "" else "disabled aria-disabled=\"true\" title=\"Inactive\"") <> ">" <> tab.label <> "</button>") tabs
    fire "modal" [value $ field "name" a <> " settings",value $
      "<form id=\"live-settings-form\" data-id=\"" <> escape (field "id" a) <> "\" class=\"form-stack\"><div class=\"settings-tabs\" role=\"tablist\" aria-label=\"Sapi settings\">" <> tabHTML <>
      "</div><section class=\"settings-panel form-stack\" role=\"tabpanel\" id=\"settings-panel-profile\" aria-labelledby=\"settings-tab-profile\" data-settings-panel=\"profile\"><label>Name<input name=\"name\" value=\"" <> escape (field "name" a) <> "\" required maxlength=\"24\" aria-describedby=\"name-help\" autocomplete=\"off\"></label>" <> string names <>
      "<label>Role<input name=\"role\" value=\"" <> escape (field "role" a) <> "\" required maxlength=\"60\"></label>" <> string managers <>
      "<label>Work mode<select name=\"mode\"><option value=\"normal\" " <> (if field "mode" execution == "normal" then "selected" else "") <> ">Normal · high</option><option value=\"deep\" " <> (if field "mode" execution == "deep" then "selected" else "") <> ">Deep work · xhigh</option></select></label><p class=\"form-hint\">Each call has a " <> string (value $ number (execution .! "timeout_seconds") / 60.0) <> "-minute limit in either mode.</p></section>" <>
      join (map (\key -> "<section class=\"settings-panel\" role=\"tabpanel\" id=\"settings-panel-" <> key <> "\" aria-labelledby=\"settings-tab-" <> key <> "\" hidden>Inactive</section>") ["context","usage","limits"]) <> "<button type=\"submit\" class=\"button primary\">Save</button></form>",value "SAPIENS4"]

computerDialog :: Effect Unit
computerDialog = do
  live <- read "live"
  let computer = live .! "computer"
      windows = field "platform" computer == "win32"
  owner <- if boolean (computer .! "owner") then exec "agent" [computer .! "owner"] <#> \a -> "In use · " <> escape (field "name" a) else pure "Available"
  fire "modal" [value "Shared computer",value $
    "<p>Blindly4 is the main computer-use tool. Ask a Sapi in chat to work on your computer.</p><div class=\"settings-row\"><span>" <> (if boolean (computer .! "built") then "Blindly4 is built" else "Build required: run " <> if windows then ".\\start.ps1" else "./start.sh") <> "</span><span class=\"tag\">" <> owner <> "</span></div><p>Sapis share one computer. " <>
    (if windows then "Windows UI Automation works with accessible apps on your desktop. Elevated apps and secure system dialogs cannot be controlled." else "macOS Accessibility access is required for desktop interaction; permission failures appear in chat.") <> "</p>",value "BLINDLY4"]

autonomyDialog :: Effect Unit
autonomyDialog = do
  fire "modal" [value "Workspace & settings",value "<p>Talk to your Sapis in chat, manage their notes, and save documents in their workspaces. Sapis can delegate requests through ChiefSapi.</p><p>Use the corpora menu to switch workspaces. Active and Paused describe execution on the host; Connecting means this device is restoring its connection.</p><button type=\"button\" class=\"button\" id=\"edit-decision-prompts\">Edit decision prompts</button>",value "SAPIENS4"]
  q "#edit-decision-prompts" >>= \button -> on button "click" false $ const $ fire "editDecisionPrompts" []

addAgent :: Effect Unit
addAgent = do
  fire "leaveGroup" [value "all"]
  input <- q "#message-input"
  bootstrap <- read "bootstrap"
  when (S.trim (field "value" input) == "") $ set input "value" $ bootstrap .! "creation_template"
  state <- read "state"
  set (state .! "drafts") (field "mainSapiId" state) (input .! "value")
  focus input
  index <- call (input .! "value") "indexOf" [value "WORKFLOW"]
  when (int index >= 0) $ void $ call input "setSelectionRange" [index,value $ int index + 8]
  fire "save" []

main :: Effect Unit
main = do
  bootstrap <- read "bootstrap"
  write "attachmentDrafts" $ bootstrap .! "attachment_drafts" <||> value {}
  write "uploading" 0
  register "attachmentLabel" \args -> pure $ value $ attachmentLabel $ at 0 args
  register "pickAttachment" \args -> pickAttachment (string $ at 0 args) $> null
  for_ [{name:"renderAttachment",action:renderAttachments},{name:"attachmentMenu",action:attachmentMenu},{name:"agentSettings",action:agentSettings},{name:"computerDialog",action:computerDialog},{name:"autonomyDialog",action:autonomyDialog},{name:"addAgent",action:addAgent}] \entry -> register entry.name \_ -> entry.action $> null
  register "mountComposer" \_ -> mount $> null

mount :: Effect Unit
mount = do
  actions <- read "actions"
  set actions "agent-settings" $ callback \_ -> agentSettings $> null
  let document = global .! "document"
      runForm form action = do
        candidate <- qIn form "button[type=submit]"
        button <- if boolean candidate then pure candidate else qIn form "button"
        unless (boolean $ button .! "disabled") do
          setField button "disabled" true
          report do
            result <- try action
            liftEffect do
              setField button "disabled" false
              case result of
                Left error -> fire "toast" [value $ message error]
                Right _ -> pure unit
  on document "submit" true \event -> do
    let form = event .! "target"
    when (field "id" form == "live-settings-form") do
      stop event
      runForm form do
        data_ <- liftEffect $ construct (global .! "FormData") [form] >>= \pairs -> call (global .! "Object") "fromEntries" [pairs]
        unless (T.test "^[A-Z][A-Za-z0-9_.:#+|()&$^\\-]*$" "" $ field "name" data_) $ liftEffect $ throw "Start with A–Z. Letters, numbers, and - _ . : # + | ( ) & $ ^ are allowed. No spaces."
        liftEffect do
          set data_ "manager" $ data_ .! "manager" <||> null
          setField data_ "execution" {mode:data_ .! "mode"}
          remove data_ "mode"
        void $ request ("/api/agents/" <> field "id" (form .! "dataset")) "PUT" data_
        void $ await $ exec "refresh" []
        liftEffect $ fire "closeModal" [] *> fire "toast" [value "Sapi saved."]
    when (field "id" form == "attachment-reference-form") do
      stop event
      runForm form do
        saveAttachment (field "id" $ form .! "dataset") $ value {kind:form .! "dataset" .! "kind",value:form .! "elements" .! "value" .! "value"}
        liftEffect $ fire "closeModal" []
  on document "click" true \event -> do
    button <- closest (event .! "target") "button"
    when (boolean button) do
      let d = button .! "dataset"
      if field "id" button == "app-menu" then stop event *> fire "appMenu" []
      else if boolean (d .! "liveTurn") then do
        stop event
        setField button "disabled" true
        report do
          result <- try do
            void $ request ("/api/agents/" <> field "owner" d <> "/turns/" <> field "id" d <> "/" <> field "liveTurn" d) "POST" $ value {}
            void $ await $ exec "refresh" []
          liftEffect do
            setField button "disabled" false
            case result of
              Left error -> fire "toast" [value $ message error]
              Right _ -> pure unit
      else when (field "id" button == "attach-button" || boolean (d .! "attachmentKind") || boolean (d .! "removeUpload")) do
        stop event
        if field "id" button == "attach-button" then attachmentMenu
        else if boolean (d .! "attachmentKind") then pickAttachment $ field "attachmentKind" d
        else do
          state <- read "state"
          drafts <- read "attachmentDrafts"
          setField drafts (field "selected" state) $ A.filter (\a -> not $ same (a .! "id") (d .! "removeUpload")) $ items (field "selected" state) drafts
          renderAttachments
          fire "save" []

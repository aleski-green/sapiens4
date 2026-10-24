module Sapiens.Groups (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Foldable (for_)
import Data.Int as Int
import Data.String as S
import Data.String.CodePoints as CP
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Aff (try)
import Data.Either (Either(..))
import Effect.Exception (message)
import Sapiens.Runtime
import Sapiens.Text as T

color :: String -> String
color text = if T.test "^#[a-f0-9]{6}$" "i" text then text else "#74b9ed"

avatar :: Value -> String -> String
avatar group size =
  let stripes = items "stripes" group
      colors = map (color <<< string) $ if A.null stripes then [group .! "color"] else stripes
      percent i = string $ value $ Int.toNumber i * 100.0 / Int.toNumber (A.length colors)
      bands = S.joinWith "," $ A.mapWithIndex (\i c -> c <> " " <> percent i <> "% " <> percent (i + 1) <> "%") colors
  in "<span class=\"avatar group-avatar " <> size <> "\" style=\"background:linear-gradient(90deg," <> bands <> ")\" aria-hidden=\"true\"><span>(" <> escape (field "face" group) <> ")</span></span>"

chip :: Value -> String -> Boolean -> String
chip group member compact =
  let lead = field "lead" group == member
      title = field "name" group <> if lead then " · Lead" else ""
  in "<button type=\"button\" class=\"group-chip\" style=\"--group-color:" <> color (field "color" group) <> "\" data-agent=\"" <> escape (field "id" group) <> "\" title=\"" <> escape title <> "\" aria-label=\"" <> escape title <> "\"><span>" <>
    escape (if compact then CP.take 1 $ field "name" group else field "name" group) <> (if lead then "★" else "") <> "</span></button>"

labels :: Value -> Boolean -> Effect String
labels sapi compact = do
  state <- read "state"
  let groups = A.filter (\g -> field "kind" g == "group" && not (boolean $ g .! "archived") && A.any (\id -> string id == field "id" sapi) (items "members" g)) $ items "agents" state
      count = A.length groups
  pure $ if count == 0 then "" else "<span class=\"group-labels " <> (if compact then "compact" else "") <> "\" style=\"--label-count:" <> show count <> ";--label-min:" <> show (22 + 3 * (count - 1)) <> "px\">" <> stringMap groups (\g -> chip g (field "id" sapi) compact) <> "</span>"

callControls :: Value -> Value -> String
callControls group request
  | not (A.elem (field "status" request) ["queued", "running", "failed", "interrupted"]) = ""
  | otherwise = "<div class=\"actions\">" <>
      (if A.elem (field "status" request) ["failed", "interrupted"] && not (boolean $ request .! "task") && not (boolean $ group .! "archived") then button "retry" "Retry" else "") <>
      button "cancel" (if field "status" request == "running" then "Stop" else if field "status" request == "queued" then "Cancel" else "Dismiss") <> "</div>"
      where button action label = "<button class=\"button\" data-group-call=\"" <> action <> "\" data-group=\"" <> escape (field "id" group) <> "\" data-call=\"" <> escape (field "id" request) <> "\">" <> label <> "</button>"

dialog :: Value -> Effect Unit
dialog group = do
  state <- read "state"
  let sapis = A.filter (\a -> field "kind" a /= "group" && not (boolean $ a .! "retired")) $ items "agents" state
      options = stringMap sapis \a -> "<option value=\"" <> escape (field "id" a) <> "\" " <> (if field "id" a == field "lead" group then "selected" else "") <> ">" <> escape (field "name" a) <> "</option>"
  members <- traverse (\a -> do
    face <- exec "avatar" [a, value "mini"]
    pure $ "<label><input type=\"checkbox\" name=\"member\" value=\"" <> escape (field "id" a) <> "\" " <> (if A.any (\id -> string id == field "id" a) (items "members" group) then "checked" else "") <> ">" <> string face <> "<span>" <> escape (field "name" a) <> "</span></label>") sapis
  fire "modal" [value $ field "name" group <> " settings", value $
    "<form id=\"group-form\" class=\"form-stack\" data-revision=\"" <> field "revision" group <> "\"><label>Name<input name=\"name\" maxlength=\"60\" value=\"" <> escape (field "name" group) <> "\" required></label>" <>
    "<label>Purpose<textarea name=\"description\" rows=\"2\" maxlength=\"2000\">" <> escape (field "description" group) <> "</textarea></label><label>Lead<select name=\"lead\">" <> options <> "</select></label>" <>
    "<fieldset class=\"group-members\"><legend>Members · at least two, including the Lead</legend>" <> join members <> "</fieldset><p class=\"form-hint\">Each Sapi can belong to up to 11 active Groups.</p><button type=\"submit\" class=\"button primary\">Save Group</button>" <>
    "<button type=\"button\" class=\"button\" data-group-archive=\"" <> escape (field "id" group) <> "\">" <> (if boolean (group .! "archived") then "Restore Group" else "Archive Group") <> "</button></form>", value "GROUP"]
  form <- q "#group-form"
  on (form .! "elements" .! "lead") "change" false \_ -> do
    inputs <- qaIn form "input[name=member]"
    for_ inputs \input -> when (same (input .! "value") (form .! "elements" .! "lead" .! "value")) $ setField input "checked" true
  on form "submit" false \event -> do
    prevent event
    button <- qIn form "[type=submit]"
    setField button "disabled" true
    report do
      result <- try do
        data_ <- liftEffect $ construct (global .! "FormData") [form]
        name <- liftEffect $ call data_ "get" [value "name"]
        description <- liftEffect $ call data_ "get" [value "description"]
        lead <- liftEffect $ call data_ "get" [value "lead"]
        members_ <- liftEffect $ call data_ "getAll" [value "member"]
        void $ request ("/api/groups/" <> field "id" group) "PUT" $ value {name,description,lead,members:members_,revision:number $ form .! "dataset" .! "revision"}
        void $ await $ exec "refresh" []
        liftEffect do
          fire "closeModal" []
          fire "openChat" [group .! "id"]
          fire "toast" [value "Group saved."]
      liftEffect do
        setField button "disabled" false
        case result of
          Left error -> fire "toast" [value $ message error]
          Right _ -> pure unit

renderPanel :: Value -> Effect Unit
renderPanel host = do
  group <- exec "selected" []
  state <- read "state"
  live <- read "live"
  toggle host "notes-view" false
  prop "#composer-area" "hidden" $ field "panel" state /= "chat" || boolean (group .! "archived")
  if field "panel" state == "updates" then fire "renderUpdates" [host]
  else if field "panel" state /= "chat" then fire "renderWork" [host]
  else do
    messages <- traverse (\message_ -> do
      author <- if field "author" message_ == "admin" then pure null else exec "agent" [message_ .! "author"]
      face <- if boolean author then string <$> exec "avatar" [author,value "mini"] else pure "<span>↗</span>"
      name <- if boolean author then string <$> exec "mention" [author .! "id"] else pure "Admin"
      time <- exec "displayTime" [message_ .! "created"]
      formatted <- string <$> exec "formatText" [message_ .! "text"]
      attachments <- traverse (\item -> string <$> exec "attachmentLabel" [item]) $ items "attachments" message_
      pure $ "<div data-chat-key=\"" <> escape (field "id" message_) <> "\" class=\"message " <> (if boolean author then "" else "user") <> "\"><div class=\"message-meta\">" <> face <> "<strong>" <> name <> "</strong><time>" <> escape (string time) <> "</time></div><div class=\"message-bubble\">" <>
        join (map (\p -> "<p>" <> T.replace "\n" "g" "<br>" p <> "</p>") $ S.split (S.Pattern "\n\n") formatted) <>
        (if A.null attachments then "" else "<div class=\"message-attachments\">" <> join attachments <> "</div>") <>
        (if boolean (message_ .! "stale") then "<small class=\"group-banner\">Result from an earlier task revision · current work was preserved.</small>" else "") <> "</div></div>") $ items "messages" group
    requests <- traverse (\request_ -> do
      let turn = find (\t -> field "id" t == field "id" request_) $ items "turns" live
      target <- exec "agent" [request_ .! "target"]
      statuses <- read "statusNames"
      active <- exec "blocksChat" [turn]
      progress <- if boolean turn && boolean active then do
        text <- exec "turnProgress" [turn]
        pure $ "<div data-turn-progress=\"" <> escape (field "id" turn) <> "\">" <> string text <> "</div>"
        else pure ""
      pure $ "<section data-chat-key=\"request:" <> escape (field "id" request_) <> "\" class=\"live-status\"><strong>" <> escape (field "name" target) <> " · " <> escape (string $ statuses .! field "status" request_ <||> request_ .! "status") <> "</strong>" <> progress <>
        (if boolean (request_ .! "error") then "<p>" <> escape (field "error" request_) <> "</p>" else "") <> callControls group request_ <> "</section>") $ A.filter (\r -> A.elem (field "status" r) ["queued", "running", "failed", "interrupted"]) $ items "requests" group
    lead <- exec "agent" [group .! "lead"]
    html host $ (if boolean (group .! "archived") then "<p class=\"group-banner\">Archived · history is preserved. Restore this Group from settings to continue.</p>" else "") <>
      "<div class=\"day-divider\">GROUP CONVERSATION</div>" <> join messages <>
      (if A.null messages then "<div class=\"empty\">Message the Group to reach " <> escape (field "name" lead) <> ", or @mention a member.</div>" else "") <> join requests
    fire "renderAttachment" []

main :: Effect Unit
main = do
  register "groupColor" \args -> pure $ value $ color $ string $ at 0 args
  register "groupAvatar" \args -> pure $ value $ avatar (at 0 args) (string $ at 1 args)
  register "groupChip" \args -> pure $ value $ chip (at 0 args) (string $ at 1 args) (boolean $ at 2 args)
  register "groupLabels" \args -> value <$> labels (at 0 args) (boolean $ at 1 args)
  register "groupDialog" \args -> dialog (at 0 args) $> null
  register "groupCallControls" \args -> pure $ value $ callControls (at 0 args) (at 1 args)
  register "renderGroupPanel" \args -> renderPanel (at 0 args) $> null
  register "mountGroups" \_ -> do
    observer <- construct (global .! "ResizeObserver") [callback \args -> do
      for_ (array $ at 0 args) \entry -> do
        let target = entry .! "target"
            count = A.length $ array $ target .! "children"
            width = number $ target .! "clientWidth"
            step = min 25.0 $ max 3.0 $ (width - 22.0) / Int.toNumber (max 1 $ count - 1)
        style (target .! "parentElement") "--name-reserve" $ string (value $ 22.0 + 3.0 * Int.toNumber (count - 1) + number (target .! "nextElementSibling" .! "offsetWidth") + 8.0) <> "px"
        style target "--label-step" $ string (value step) <> "px"
        toggle target "colour-only" $ count > 1 && step < 18.0
      pure null]
    register "observeGroupLabels" \_ -> do
      void $ call observer "disconnect" []
      qa ".group-labels.compact" >>= flip for_ (\node -> void $ call observer "observe" [node])
      pure null
    pure null

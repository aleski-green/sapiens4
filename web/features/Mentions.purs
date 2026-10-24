module Sapiens.Mentions (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Effect (Effect)
import Sapiens.Runtime
import Sapiens.Text as T

close :: Effect Unit
close = do
  menu <- q "#mention-suggestions"
  when (boolean menu) $ void $ call menu "remove" []
  input <- q "#message-input"
  attr input "aria-expanded" "false"
  void $ call input "removeAttribute" [value "aria-activedescendant"]
  write "mentionRange" null
  write "mentionChoices" ([] :: Array Value)

draw :: Effect Unit
draw = do
  existing <- q "#mention-suggestions"
  menu <- if boolean existing then pure existing else do
    node <- element "div" "mention-suggestions" ""
    setField node "id" "mention-suggestions"
    attr node "role" "listbox"
    attr node "aria-label" "Sapis"
    q "#chat-form" >>= \form -> append form [node]
    pure node
  choices <- array <$> read "mentionChoices"
  index <- int <$> read "mentionIndex"
  html menu $ if A.null choices then "<div class=\"empty\">No matching Sapis.</div>" else join $ A.mapWithIndex (\i entity ->
    "<button type=\"button\" role=\"option\" id=\"mention-option-" <> show i <> "\" aria-selected=\"" <> show (i == index) <> "\" data-mention-choice=\"" <> show i <>
    "\"><strong>@" <> escape (field "name" entity) <> "</strong><small>Sapi</small></button>") choices
  input <- q "#message-input"
  attr input "aria-controls" "mention-suggestions"
  attr input "aria-expanded" "true"
  unless (A.null choices) $ attr input "aria-activedescendant" $ "mention-option-" <> show index

update :: Effect Unit
update = do
  input <- q "#message-input"
  let before = CU.take (int $ input .! "selectionStart") $ field "value" input
      match = A.head $ T.matches "(?:^|\\s)@([A-Za-z0-9_.:#+|()&$^\\-]*)$" "" before
  case match >>= T.group 1 of
    Nothing -> close
    Just prefix -> if not (same (input .! "selectionStart") (input .! "selectionEnd")) then close else do
      state <- read "state"
      selected <- exec "selected" []
      write "mentionRange" {start:int (input .! "selectionStart") - CU.length prefix - 1, end:input .! "selectionStart"}
      write "mentionChoices" $ A.take 12 $ A.filter (\a -> field "kind" a /= "group" && not (boolean $ a .! "retired") &&
        (field "kind" selected /= "group" || A.any (\id -> string id == field "id" a) (items "members" selected)) &&
        CU.take (CU.length prefix) (S.toLower $ field "name" a) == S.toLower prefix) $ items "agents" state
      write "mentionIndex" 0
      draw

choose :: Int -> Effect Unit
choose index = do
  choices <- array <$> read "mentionChoices"
  range <- read "mentionRange"
  let entity = at index choices
  when (boolean entity && boolean range) do
    input <- q "#message-input"
    void $ call input "setRangeText" [value $ "@" <> field "name" entity <> " ", range .! "start", range .! "end", value "end"]
    state <- read "state"
    set (state .! "drafts") (field "selected" state) (input .! "value")
    fire "save" []
    close
    focus input

main :: Effect Unit
main = do
  write "mentionRange" null
  write "mentionChoices" ([] :: Array Value)
  write "mentionIndex" 0
  register "formatText" \args -> do
    state <- read "state"
    let entities = map (\a -> {id:field "id" a, name:field "name" a}) $ items "agents" state
    pure $ value $ T.formatText entities $ string $ at 0 args
  for_ [{name:"closeMentions", action:close}, {name:"updateMentions", action:update}, {name:"drawMentions", action:draw}] \entry ->
    register entry.name \_ -> entry.action $> null
  register "chooseMention" \args -> choose (int $ at 0 args) $> null
  register "mountMentions" \_ -> do
    let document = global .! "document"
    on document "input" false \event -> when (field "id" (event .! "target") == "message-input") update
    on document "click" true \event -> do
      let target = event .! "target"
      choice <- closest target "[data-mention-choice]"
      if boolean choice then stop event *> choose (int $ choice .! "dataset" .! "mentionChoice")
      else do
        page <- closest target "a.chat-link"
        if boolean page && boolean (global .! "window" .! "webkit" .! "messageHandlers" .! "browser") &&
            field "location" (global .! "window" .! "SapiensConnections" .! "active") /= "Remote" then
          stop event *> fire "browserAction" [value "open", value {url:page .! "href"}]
        else do
          file <- closest target "[data-file-link]"
          if boolean file then do
            prevent event
            close
            destination <- exec "browserDestination" [file .! "dataset" .! "fileLink"]
            fire "browserAction" [value "open", destination]
          else if field "id" target == "message-input" then update else close
    on document "keydown" true \event -> do
      range <- read "mentionRange"
      let key = field "key" event
      when (field "id" (event .! "target") == "message-input" && boolean range && not (boolean $ event .! "isComposing") && A.elem key ["ArrowDown", "ArrowUp", "Enter", "Tab", "Escape"]) do
        stop event
        if key == "Escape" then close else do
          choices <- array <$> read "mentionChoices"
          index <- int <$> read "mentionIndex"
          unless (A.null choices) do
            if key == "Enter" || key == "Tab" then choose index
            else write "mentionIndex" (mod (index + (if key == "ArrowDown" then 1 else -1) + A.length choices) (A.length choices)) *> draw
    pure null

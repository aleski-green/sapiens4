module Sapiens.Names (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Traversable (traverse)
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.String as S
import Effect (Effect)
import Effect.Random (randomInt)
import Sapiens.Runtime

pools :: Array (Array String)
pools =
  [ ["Armin","Howl","Seneca","Socrates","Aesop","Nikola","Walt","Akira","Milo"]
  , ["Kiki","Chihiro","Sophie","Alice","Hypatia","Simone","Ada","Oprah","Arianna"]
  , ["Sage","River","Rowan","Sky","Nova","Phoenix","Ash","Robin","Aster"] ]

suggestedNames :: Effect (Array String)
suggestedNames = do
  state <- read "state"
  let used = map (S.toLower <<< field "name") $ items "agents" state
  traverse (\pool -> do
    let available = A.filter (not <<< flip A.elem used <<< S.toLower) pool
    names <- if A.null available then traverse (\name -> randomInt 10 99 <#> \n -> name <> "-" <> show n) pool else pure available
    index <- randomInt 0 (A.length names - 1)
    pure $ fromMaybe "Sapi" $ A.index names index) pools

suggestions :: Effect String
suggestions = do
  names <- suggestedNames
  pure $ "<div class=\"name-suggestions\" id=\"name-help\" aria-label=\"Suggested names\">" <>
    join (map (\name -> "<button type=\"button\" class=\"button\" data-use-name=\"" <> escape name <> "\">" <> escape name <> "</button>") names) <>
    "<button type=\"button\" class=\"icon-button\" data-more-names=\"true\" aria-label=\"More name suggestions\">↻</button></div>"

managerOptions :: Value -> Effect String
managerOptions a = do
  live <- read "live"
  state <- read "state"
  if field "id" a == field "main_agent_id" live then pure "<div class=\"settings-row\"><span>Main orchestrator</span></div>"
  else do
    let info = live .! "orchestration" .! field "id" a
        allowed candidate = not (boolean $ candidate .! "retired") && field "kind" candidate /= "group" && ascend [] (field "id" candidate)
        ascend seen id
          | id == "" = true
          | id == field "id" a || A.elem id seen = false
          | otherwise = ascend (A.snoc seen id) $ field "manager" $ live .! "orchestration" .! id
    pure $ "<label>Manager<select name=\"manager\">" <> stringMap (A.filter allowed $ items "agents" state) (\candidate ->
      "<option value=\"" <> escape (field "id" candidate) <> "\" " <> (if field "id" candidate == field "manager" info then "selected" else "") <> ">" <>
      escape (field "name" candidate) <> (if field "id" candidate == field "main_agent_id" live then " · Main orchestrator" else "") <> "</option>") <> "</select></label>"

main :: Effect Unit
main = do
  register "suggestedNames" \_ -> value <$> suggestedNames
  register "nameSuggestions" \_ -> value <$> suggestions
  register "managerOptions" \args -> value <$> managerOptions (at 0 args)
  register "mountNames" \_ -> do
    on (global .! "document") "click" true \event -> do
      button <- closest (event .! "target") "button"
      let d = button .! "dataset"
      when (boolean (d .! "useName") || boolean (d .! "moreNames")) do
        stop event
        if boolean (d .! "useName") then do
          form <- closest button "form"
          let input = form .! "elements" .! "name"
          set input "value" $ d .! "useName"
          focus input
        else do
          current <- q "#name-help"
          holder <- element "div" "" ""
          suggestions >>= html holder
          void $ call current "replaceWith" [holder .! "firstElementChild"]
    pure null

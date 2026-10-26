module Sapiens.Text where

import Prelude
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.String.Regex as R
import Data.String.Regex.Flags (RegexFlags, noFlags, unicode)
import Data.Tuple (Tuple(..))
import Libs4.Browser as B
import Sapiens.Action (Action(..))
import Sapiens.Data as D
import Sapiens.Html as V
import Sapiens.Model as M

color :: String -> String
color value = if D.matches "^#[a-fA-F0-9]{6}$" value then value else "#74b9ed"

avatar :: Json -> String -> Boolean -> V.Html
avatar a size presence = V.node "span" [V.cls $ "avatar " <> (if M.isGroup a then "group-avatar " else "") <> size,V.style (if M.isGroup a then "background:linear-gradient(90deg," <> bands <> ")" else "--avatar-color:" <> color (D.s "color" a)),V.attr "aria-hidden" "true"]
  [V.span [] ("(" <> D.s "face" a <> ")"),V.when presence $ V.node "i" [V.cls $ "presence " <> if D.s "status" a == "busy" then "busy" else ""] []]
  where
  colors = if A.null $ D.rows "stripes" a then [D.s "color" a] else D.strings $ D.get "stripes" a
  bands = S.joinWith "," $ A.mapWithIndex (\i c -> color c <> " " <> show (i * 100 / A.length colors) <> "% " <> show ((i + 1) * 100 / A.length colors) <> "%") colors

mention :: M.Model -> String -> V.Html
mention m id = let a = D.find id m.agents in if D.valid a then V.control [V.cls "entity-mention",V.label $ "Open chat with " <> D.s "name" a] ("@" <> D.s "name" a) (Select id) else V.text $ if id == "you" then "You" else id

groupLabels :: M.Model -> Json -> Boolean -> V.Html
groupLabels m sapi compact = V.node "span" [V.cls $ "group-labels " <> if compact then "compact" else "",V.style $ "--label-count:" <> show (A.length groups) <> ";--label-step:22px;--label-min:22px"] $ map chip groups
  where
  groups = A.filter (\g -> M.isGroup g && not (D.b "archived" g) && D.has (D.s "id" sapi) (D.get "members" g)) m.agents
  chip g = let lead = D.s "lead" g == D.s "id" sapi
               title = D.s "name" g <> if lead then " · Lead" else ""
           in V.node "button" [V.attr "type" "button",V.cls "group-chip",V.style $ "--group-color:" <> color (D.s "color" g),V.label title,V.attr "title" title,V.click $ Select $ D.s "id" g] [V.span [] ((if compact then S.take 1 $ D.s "name" g else D.s "name" g) <> if lead then "★" else "")]

type Match = { before :: String, full :: String, groups :: Array String, after :: String }

match :: String -> String -> Maybe Match
match = matchWith noFlags

matchWith :: RegexFlags -> String -> String -> Maybe Match
matchWith flags pattern value = case R.regex pattern flags of
  Left _ -> Nothing
  Right regex -> do
    index <- R.search regex value
    groups <- R.match regex value
    let values = map (fromMaybe "") (NEA.toArray groups)
        full = fromMaybe "" $ A.head values
    if full == "" then Nothing else Just {before:CU.take index value,full,groups:values,after:CU.drop (index+CU.length full) value}

mentions :: M.Model -> String -> Array V.Html
mentions m value = if A.null m.agents then [V.text value] else case matchWith unicode pattern value of
  Nothing -> [V.text value]
  Just hit -> [V.text hit.before,if A.length candidates == 1 then mention m (D.s "id" $ D.first candidates) else V.text hit.full] <> mentions m hit.after
    where
    candidates = A.filter (\a -> D.s "name" a == D.replace "^@" "" hit.full) m.agents
  where
  names = A.sortBy (\a b -> compare (CU.length b) (CU.length a)) $ A.nub $ map (D.s "name") m.agents
  escape = D.replace "[.*+?^${}()|[\\]\\\\]" "\\$&"
  pattern = "(?<![\\p{L}\\p{N}_@.-])@?(?:" <> S.joinWith "|" (map escape names) <> ")(?![\\p{L}\\p{N}_@:-])"

link :: String -> String -> V.Html
link destination caption =
  if S.take 1 destination == "/" || S.take 7 destination == "file://" then V.control [V.cls "entity-mention"] (D.fallback destination caption) (Browser "open" $ D.obj [Tuple (if S.take 7 destination == "file://" then "url" else "path") (D.text destination)])
  else if A.elem (D.s "protocol" url) ["http:","https:"] then V.textNode "a" [V.cls "chat-link",V.attr "href" (D.s "href" url),V.attr "title" destination,V.attr "target" "_blank",V.attr "rel" "noopener noreferrer",V.on "click" \event -> Link event (OpenLink $ D.s "href" url)] (label <> " ↗")
  else V.text $ D.fallback destination caption
  where
  url = B.parseURL "about:blank" destination
  tail = B.decodeURI $ fromMaybe "" $ A.last $ A.filter (_ /= "") $ S.split (S.Pattern "/") $ D.s "path" url
  label = D.fallback (D.s "host" url <> if tail == "" then "" else " · " <> if CU.length tail > 48 then CU.take 45 tail <> "…" else tail) caption

format :: M.Model -> String -> Array V.Html
format m value = go (collect value) value
  where
  group hit i = fromMaybe "" $ A.index hit.groups i
  collect source = case match pattern source of
    Nothing -> []
    Just hit -> (if group hit 1 == "" then [] else [D.fallback (group hit 3) $ group hit 2]) <> collect hit.after
  citation hit = do
    parsed <- match "(?:^|\\s)path=\"((?:\\\\.|[^\"\\\\])*)\"" $ group hit 6
    let path = D.replace "\\\\([\\\\_\"])" "$1" $ group parsed 1
    if S.take 1 path == "/" || S.take 7 path == "file://" then Just path else Nothing
  go files source = case match pattern source of
    Nothing -> mentions m source
    Just hit -> case citation hit of
      Just path -> mentions m hit.before <> (if A.elem path files then [] else [link path (fromMaybe path $ A.last $ S.split (S.Pattern "/") path)]) <> go (A.snoc files path) hit.after
      Nothing -> mentions m hit.before <> token hit <> go files hit.after
  trimURL url = if CU.drop (CU.length url-1) url == ")" && A.length (S.split (S.Pattern ")") url) > A.length (S.split (S.Pattern "(") url) then trimURL (CU.take (CU.length url-1) url) else url
  pattern = "\\[([^\\]\\n]+)\\]\\((?:<([^>\\n]+)>|((?:[^()\\s]|\\([^()\\s]*\\))+))\\)|https?://[^\\s<>]+|`([^`\\n]+)`|\\*\\*([^*\\n]+)\\*\\*|:codex-file-citation\\{((?:[^{}\"\\n]|\"(?:\\\\.|[^\"\\\\\\n])*\")*)\\}"
  token hit =
    let g i = fromMaybe "" $ A.index hit.groups i
    in if g 1 /= "" then [link (D.fallback (g 3) $ g 2) (g 1)]
    else if g 4 /= "" then [V.textNode "code" [] (g 4)]
    else if g 5 /= "" then [V.node "strong" [] $ mentions m $ g 5]
    else if g 6 /= "" then [V.text hit.full]
    else let url = trimURL $ D.replace "[.,;:!?]+$" "" hit.full in [link url "",V.text $ CU.drop (CU.length url) hit.full]

paragraphs :: M.Model -> String -> Array V.Html
paragraphs m = map (V.node "p" [] <<< A.intercalate [V.node "br" [] []] <<< map (format m) <<< S.split (S.Pattern "\n")) <<< S.split (S.Pattern "\n\n")

time :: String -> String
time = B.formatDate "" $ D.json {hour: "2-digit", minute: "2-digit"}

attachment :: Json -> V.Html
attachment item = if D.s "kind" item == "link" then V.link (D.s "value" item) (caption <> " ↗") else V.span [V.cls "attachment-item",V.attr "title" (D.s "value" item)] (caption)
  where
  kind = D.s "kind" item
  caption = S.toUpper (S.take 1 kind) <> S.drop 1 kind <> " · " <> D.s "name" item

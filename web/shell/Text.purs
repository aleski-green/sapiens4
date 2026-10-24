module Sapiens.Text
  ( Match, URL, Entity, matches, test, replace, escape, group, url, decode, encode, slice, length, main, formatText ) where

import Prelude
import Control.Alt ((<|>))
import Data.Array as A
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Nullable (Nullable, toMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Uncurried (mkEffectFn2)
import Sapiens.Browser as B

type Match = {index :: Int, value :: String, groups :: Array (Nullable String)}
type URL = {href :: String, protocol :: String, hostname :: String, pathname :: String}
type Entity = {id :: String, name :: String}

foreign import matches :: String -> String -> String -> Array Match
foreign import test :: String -> String -> String -> Boolean
foreign import replace :: String -> String -> String -> String -> String
foreign import url :: String -> String -> Nullable URL
foreign import decode :: String -> String
foreign import encode :: String -> String

slice :: Int -> Int -> String -> String
slice start end = CU.take (max 0 (end - start)) <<< CU.drop start

length :: String -> Int
length = CU.length

group :: Int -> Match -> Maybe String
group index match = A.index match.groups (index - 1) >>= toMaybe

escape :: String -> String
escape = S.replaceAll (S.Pattern "'") (S.Replacement "&#39;")
  <<< S.replaceAll (S.Pattern "\"") (S.Replacement "&quot;")
  <<< S.replaceAll (S.Pattern ">") (S.Replacement "&gt;")
  <<< S.replaceAll (S.Pattern "<") (S.Replacement "&lt;")
  <<< S.replaceAll (S.Pattern "&") (S.Replacement "&amp;")

mention :: Entity -> String
mention entity = "<button type=\"button\" class=\"entity-mention\" data-mention=\"" <> escape entity.id <>
  "\" aria-label=\"Open chat with " <> escape entity.name <> "\">@" <> escape entity.name <> "</button>"

formatMentions :: Array Entity -> String -> String
formatMentions entities value
  | A.null entities = escape value
  | otherwise = result.output <> escape (CU.drop result.cursor value)
  where
  names = A.nub $ map (_.name) $ A.sortBy (\a b -> compare (length b.name) (length a.name)) entities
  pattern = "(?<![\\p{L}\\p{N}_@.-])@?(?:" <> S.joinWith "|" (map (replace "[.*+?^${}()|[\\]\\\\]" "g" "\\$&") names) <> ")(?![\\p{L}\\p{N}_@:-])"
  result = foldl (\acc match ->
    let candidates = A.filter (\e -> e.name == replace "^@" "" "" match.value) entities
        label = case candidates of
          [entity] -> mention entity
          _ -> escape match.value
    in {output: acc.output <> escape (slice acc.cursor match.index value) <> label, cursor: match.index + length match.value})
    {output: "", cursor: 0} (matches pattern "gu" value)

chatLink :: String -> String -> String
chatLink destination label
  | test "^(/|file://)" "" destination = "<button type=\"button\" class=\"entity-mention\" data-file-link=\"" <> escape destination <> "\">" <> escape (if label == "" then destination else label) <> "</button>"
  | otherwise = case toMaybe (url destination "") of
      Just address | A.elem address.protocol ["http:", "https:"] ->
        let tail = decode $ fromMaybe "" $ A.last $ A.filter (_ /= "") $ S.split (S.Pattern "/") address.pathname
            shortened = if length tail > 48 then CU.take 45 tail <> "…" else tail
            caption = if label /= "" then label else address.hostname <> if shortened == "" then "" else " · " <> shortened
        in "<a class=\"chat-link\" href=\"" <> escape address.href <> "\" title=\"" <> escape destination <>
          "\" target=\"_blank\" rel=\"noopener noreferrer\">" <> escape caption <> " ↗</a>"
      _ -> escape (if label == "" then destination else label)

formatText :: Array Entity -> String -> String
formatText entities value = result.output <> formatMentions entities (CU.drop result.cursor value)
  where
  tokens = matches "\\[([^\\]\\n]+)\\]\\((?:<([^>\\n]+)>|((?:[^()\\s]|\\([^()\\s]*\\))+))\\)|https?://[^\\s<>]+|`([^`\\n]+)`|\\*\\*([^*\\n]+)\\*\\*|:codex-file-citation\\{((?:[^{}\"\\n]|\"(?:\\\\.|[^\"\\\\\\n])*\")*)\\}" "g" value
  initialFiles = A.mapMaybe (\m -> if isJust (group 1 m) then group 2 m <|> group 3 m else Nothing) tokens
  trimURL link
    | test "\\)$" "" link && A.length (matches "\\)" "g" link) > A.length (matches "\\(" "g" link) = trimURL $ CU.take (length link - 1) link
    | otherwise = link
  step acc m =
    let Tuple rendered files = case group 1 m, group 4 m, group 5 m, group 6 m of
          Just label, _, _, _ -> Tuple (chatLink (fromMaybe "" $ group 2 m <|> group 3 m) label) acc.files
          _, Just code, _, _ -> Tuple ("<code>" <> escape code <> "</code>") acc.files
          _, _, Just bold, _ -> Tuple ("<strong>" <> formatMentions entities bold <> "</strong>") acc.files
          _, _, _, Just citation ->
            let path = A.head (matches "(?:^|\\s)path=\"((?:\\\\.|[^\"\\\\])*)\"" "" citation) >>= group 1
                cleaned = replace "\\\\([\\\\_\"])" "g" "$1" <$> path
            in case cleaned of
              Just file | test "^(/|file://)" "" file ->
                if A.elem file acc.files then Tuple "" acc.files
                else Tuple (chatLink file $ fromMaybe "" $ A.last $ S.split (S.Pattern "/") file) (A.snoc acc.files file)
              _ -> Tuple (escape m.value) acc.files
          _, _, _, _ ->
            let link = trimURL $ replace "[.,;:!?]+$" "" "" m.value
            in Tuple (chatLink link "" <> escape (CU.drop (length link) m.value)) acc.files
    in {output: acc.output <> formatMentions entities (slice acc.cursor m.index value) <> rendered, cursor: m.index + length m.value, files}
  result = foldl step {output: "", cursor: 0, files: initialFiles} tokens

main :: Effect Unit
main = B.expose "SapiensText" {formatText: mkEffectFn2 \entities value -> pure $ formatText entities value}

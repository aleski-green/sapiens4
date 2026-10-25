module Sapiens.Memo where

import Prelude
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))
import Foreign.Object as O
import Libs4.Browser as B
import Sapiens.Action (Action(..))
import Sapiens.Data as D
import Sapiens.Html as V
import Sapiens.Model as M
import Sapiens.Text as T

attribute :: String -> Json -> String
attribute key node = D.str $ D.at ["attrs",key] node

walk :: Array Json -> Array Json
walk nodes = nodes <> A.concatMap (walk <<< D.rows "children") nodes

imagePaths :: Json -> Array String
imagePaths document = A.nub $ A.mapMaybe (\n -> let source = attribute "src" n in if D.s "tag" n == "img" && source /= "" && not (D.matches "^(?:[a-zA-Z]+:|//|/)" source) then Just source else Nothing) $ walk $ D.arr $ B.parseMarkup $ D.s "content" document

allowedTags :: Array String
allowedTags = S.split (S.Pattern " ") "section article nav div p span h2 h3 h4 blockquote sup sub pre code a img table thead tbody tfoot tr td th caption ul ol li dl dt dd details summary figure figcaption strong em b i small br hr"

emptyEntry :: Json -> Boolean
emptyEntry node =
  let nodes = walk $ D.rows "children" node
      codes = A.filter (( _ == "code") <<< D.s "tag") nodes
      placeholder code = A.all (\line -> S.trim line == "" || D.matches "^\\s*[\\w-]+:\\s*(?:[\"']?\\*\\*\\*[\"']?|\\{\\}|\\[\\])\\s*$" line) $ S.split (S.Pattern "\n") $ D.s "text" code
  in A.elem (D.s "tag" node) ["article","details"] && not (A.null codes) && A.all placeholder codes && not (A.any (\n -> A.elem (D.s "tag" n) ["img","a","p","table","blockquote"]) nodes)

facts :: Boolean -> String -> Maybe V.Html
facts about source = if A.null lines || not (A.all (\line -> S.trim line == "" || D.matches "^\\s*(?:[\\w-]+\\s*:|[-#] |[ \\t]+\\S)" line) lines) then Nothing else Just $ V.div "memo-facts" $ renderLines lines
  where
  lines = S.split (S.Pattern "\n") $ S.trim source
  scalar value = D.fallback value $ D.str $ D.parse value
  renderLines remaining = case A.uncons remaining of
    Nothing -> []
    Just {head:line,tail} -> case T.match "^(\\s*)([\\w-]+):\\s*(.*)$" line of
      Nothing -> [V.p "" $ S.trim line] <> renderLines tail
      Just hit ->
        let group i = fromMaybe "" $ A.index hit.groups i
            value = group 3
            indent = CU.length $ group 1
            block = A.takeWhile (\l -> S.trim l == "" || CU.length (D.replace "[^ ].*$" "" l) > indent) tail
            multiline = D.matches "^[|>][+-]?$" value
            body = if multiline then S.joinWith (if S.take 1 value == ">" then " " else "\n") $ map S.trim block else scalar value
        in [V.node "p" [] $ (if about then [] else [V.node "strong" [] [V.text $ D.replace "_" " " (group 2) <> ": "]]) <> [V.text body]] <> renderLines (if multiline then A.drop (A.length block) tail else tail)

highlight :: String -> String -> Array V.Html
highlight language source = case pattern language of
  "" -> [V.text source]
  regex -> case T.match regex source of
    Nothing -> [V.text source]
    Just hit -> [V.text hit.before,V.node "span" [V.cls $ "syntax-" <> kind hit.groups] [V.text hit.full]] <> highlight language hit.after
  where
  kind groups = if fromMaybe "" (A.index groups 1) /= "" then "string" else if fromMaybe "" (A.index groups 2) /= "" then "comment" else if fromMaybe "" (A.index groups 3) /= "" then "keyword" else "literal"
  pattern = case _ of
    "yaml" -> "(\"(?:\\\\.|[^\"\\\\])*\"|'(?:''|[^'])*')|((?<!\\S)#[^\\n]*)|(\\b[A-Za-z_][\\w-]*(?=:\\s|:$))|(\\b(?:true|false|null|\\d+(?:\\.\\d+)?)\\b|[{}[\\]:,|>])"
    "python" -> "(\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')|(#[^\\n]*)|(\\b(?:def|class|import|from|as|return|if|elif|else|for|while|in|is|not|and|or|with|try|except|raise|yield|async|await|pass|lambda)\\b)|(\\b(?:True|False|None|\\d+(?:\\.\\d+)?)\\b)"
    "haskell" -> "(\"(?:\\\\.|[^\"\\\\])*\")|(--[^\\n]*|\\{-[\\s\\S]*?-\\})|(\\b(?:data|type|newtype|where|let|in|case|of|if|then|else|do|module|import|deriving)\\b|::|->|<-|=>)|(\\b(?:[A-Z]\\w*|\\d+)\\b)"
    "html" -> "(\"[^\"]*\"|'[^']*')|(<!--[\\s\\S]*?-->)|(<\\/?[\\w-]+|/?>)|(\\b[\\w-]+(?=\\s*=))"
    "svg" -> pattern "html"
    _ -> ""

view :: M.Model -> V.Html
view m = case document of
  M.Failed _ error -> V.div "" [V.p "empty" error,V.button "button" "Try again" $ RetryDocument key]
  _ -> case M.valueOf document of
    Nothing -> if D.s "revision" info == "missing" then V.p "empty" "No shared Memo yet." else V.text "Loading Memo…"
    Just row -> case wiki m row info of
      Left error -> V.p "empty" error
      Right html -> html
  where
  key = "memo:" <> m.selected
  document = fromMaybe M.NotAsked $ O.lookup key m.documents
  profile = M.selected m
  info = if M.isGroup profile then D.get "notes" profile else D.at ["orchestration",m.selected,"notes"] m.snapshot

wiki :: M.Model -> Json -> Json -> Either String V.Html
wiki m document info =
  if A.length sections /= 3 || map (D.s "tag") sections /= ["section","section","section"] || map (attribute "id") sections /= ["about","map","content"] then Left "Notes.html requires exactly three sections: about, map, content."
  else if A.length ids /= A.length (A.nub ids) then Left "Notes.html section anchors must be unique."
  else Right $ V.div "notes-wiki" [header,about,toc,content]
  where
  profile = M.selected m
  sections = A.filter (( _ /= "") <<< D.s "tag") $ D.arr $ B.parseMarkup $ D.s "content" document
  nodes = walk sections
  ids = A.filter (_ /= "") $ map (attribute "id") nodes
  section id = fromMaybe D.null $ A.find (( _ == id) <<< attribute "id") sections
  metadata = D.merge info $ D.get "metadata" document
  emptyNodes = A.filter emptyEntry $ walk [section "content"]
  emptyIds = A.filter (_ /= "") $ map (attribute "id") $ walk emptyNodes
  headingName id = let link = A.find (( _ == "#" <> id) <<< attribute "href") $ walk [section "map"] in D.fallback (D.replace "[-_]" " " id) $ D.s "text" $ fromMaybe D.null link
  language node = fromMaybe "text" $ A.find (\lang -> S.contains (S.Pattern $ "language-" <> lang) $ attribute "class" node) ["yaml","python","html","svg","haskell"]
  copy isAbout node
    | D.s "tag" node == "" = V.text $ D.s "text" node
    | emptyEntry node = V.empty
    | D.s "tag" node == "svg" = V.node "img" [V.attr "src" $ "data:image/svg+xml," <> B.encodeURI (D.s "source" node),V.attr "alt" $ D.fallback "Diagram" $ attribute "aria-label" node] []
    | not (A.elem (D.s "tag" node) allowedTags) = V.empty
    | otherwise = renderNode isAbout node
  renderNode isAbout node =
    let tag = D.s "tag" node
        id = attribute "id" node
        attrs = (if D.matches "^[a-zA-Z][\\w-]*$" id then [V.id $ "note-" <> id] else []) <> [V.cls $ S.joinWith " " $ A.filter (\cls -> A.elem cls ["citation","permalink","references","origin","backref","wiki-table","file-list","stub-note","draft-note"]) $ S.split (S.Pattern " ") $ attribute "class" node] <> A.mapMaybe (\key -> if D.matches "^[1-9]\\d?$" $ attribute key node then Just $ V.attr key $ attribute key node else Nothing) ["colspan","rowspan"]
        children = D.rows "children" node
        heading = if tag == "article" && not (A.any (( _ == "h2") <<< D.s "tag") children) then [V.node "h2" [] [V.text $ headingName id]] else []
    in case tag of
      "code" -> V.node "code" (attrs <> [V.attr "data-language" $ language node]) $ highlight (language node) $ D.s "text" node
      "pre" -> case A.head $ A.filter (( _ == "code") <<< D.s "tag") children of
        Just code | language code == "yaml" -> fromMaybe (V.node "pre" (attrs <> [V.attr "data-language" "yaml"]) $ map (copy isAbout) children) $ facts isAbout $ D.s "text" code
        Just code -> V.node "pre" (attrs <> [V.attr "data-language" $ language code]) $ map (copy isAbout) children
        _ -> V.node "pre" attrs $ map (copy isAbout) children
      "a" ->
        let href = attribute "href" node
            url = B.parseURL ("file://" <> D.s "path" document) href
        in if D.matches "^#[a-zA-Z][\\w-]*$" href then V.node "a" (attrs <> [V.attr "href" $ "#note-" <> S.drop 1 href,V.on "click" \e -> Link e (NoteAnchor $ "note-" <> S.drop 1 href)]) $ map (copy isAbout) children
        else if D.s "protocol" url == "file:" then V.node "a" (attrs <> [V.attr "href" "#",V.on "click" \e -> Link e $ Browser "open" $ D.obj [Tuple "path" $ D.text $ B.decodeURI $ D.s "path" url]]) $ map (copy isAbout) children
        else if A.elem (D.s "protocol" url) ["http:","https:"] then V.node "a" (attrs <> [V.cls "chat-link",V.attr "href" $ D.s "href" url,V.attr "target" "_blank",V.attr "rel" "noopener noreferrer",V.on "click" \e -> Link e $ OpenLink $ D.s "href" url]) $ map (copy isAbout) children
        else V.node "span" attrs $ map (copy isAbout) children
      "img" ->
        let src = attribute "src" node
            safe = if D.matches "^data:image/(?:png|jpeg|gif|webp|svg\\+xml)[;,]" src then src else D.str $ D.at [m.selected <> ":" <> src] m.imageUrls
        in V.node "img" (attrs <> [V.attr "alt" $ attribute "alt" node] <> if safe == "" then [] else [V.attr "src" safe]) []
      "details" -> V.node "div" attrs $ map (copy isAbout) children
      "summary" -> V.node "h3" attrs [V.text $ D.s "text" node]
      _ -> V.node tag attrs $ heading <> map (copy isAbout) children
  displayName = D.fallback (D.fallback "Sapi" $ D.s "name" profile) $ attribute "data-memo-name" $ section "about"
  history label date author = V.node "span" [] [V.text $ label <> " ",V.node "time" [V.attr "datetime" date] [V.text $ D.fallback "not recorded" $ B.formatDate "en-GB" (D.obj [Tuple "day" (D.text "numeric"),Tuple "month" (D.text "short"),Tuple "year" (D.text "numeric"),Tuple "hour" (D.text "2-digit"),Tuple "minute" (D.text "2-digit"),Tuple "timeZoneName" (D.text "short")]) date],V.text " by ",V.node "span" [V.cls "memo-actor"] [V.text $ D.fallback "unrecorded actor" author]]
  header = V.node "header" [V.cls "memo-header"] [V.node "p" [V.cls "memo-meta"] [history "Last modified at" (D.s "modified_at" metadata) (D.s "modified_by" metadata),history "Created at" (D.s "created_at" metadata) (D.s "created_by" metadata)]]
  turns = A.length $ A.filter (\t -> D.s (if M.isGroup profile then "group" else "agent") t == m.selected) $ D.rows "turns" m.snapshot
  infobox = V.node "aside" [V.cls "memo-infobox",V.label $ displayName <> " at a glance"]
    [V.div "memo-identity" [V.node "span" [V.cls "memo-avatar",V.style $ "background-color:" <> T.color (D.s "color" profile)] [V.text $ "(" <> D.fallback "◠‿◠" (D.s "face" profile) <> ")"],V.node "strong" [] [V.text displayName]]
    ,V.node "table" [] $ A.mapMaybe (\(Tuple key value) -> if value == "" then Nothing else Just $ V.node "tr" [] [V.node "th" [] [V.text key],V.node "td" [V.cls $ if S.contains (S.Pattern " ID") key then "memo-id" else ""] [V.text value]]) [Tuple "Full name" (if displayName == D.s "name" profile then "" else D.s "name" profile),Tuple "Role" (D.fallback (D.s "role" profile) $ attribute "data-memo-role" $ section "about"),Tuple "Assists" (attribute "data-memo-assists" $ section "about"),Tuple "History" (show turns <> " recorded turns"),Tuple (if M.isGroup profile then "Group ID" else "Sapi ID") m.selected]
    ,V.div "memo-workspace" [V.node "strong" [] [V.text "Workspace"],V.node "code" [] [V.text $ D.fallback (D.replace "/[^/]+$" "" $ D.s "path" document) $ D.s "workspace" metadata]]]
  about = V.node "section" [V.id "note-about",V.cls "memo-lead"] $ [infobox] <> map (copy true) (D.rows "children" $ section "about")
  entries = A.nubBy (\a b -> compare a.id b.id) $ A.mapMaybe entry $ walk [section "content"]
  entry n =
    let tag = D.s "tag" n
        id = attribute "id" n
    in if A.elem tag ["article","h2"] && id /= "" && not (A.elem id emptyIds) then Just {id,text:if tag == "article" then headingName id else D.s "text" n} else Nothing
  toc = V.when (A.length entries > 1) $ V.node "nav" [V.id "note-map",V.cls "memo-toc",V.label "Contents"] [V.node "strong" [] [V.text "Contents"],V.node "ol" [] $ map (\item -> V.node "li" [] [V.node "a" [V.attr "href" $ "#note-" <> item.id,V.on "click" \e -> Link e $ NoteAnchor $ "note-" <> item.id] [V.text item.text]]) entries]
  populated = A.filter (not <<< emptyEntry) $ D.rows "children" $ section "content"
  content = V.node "section" [V.id "note-content"] $ (if A.any (\n -> A.elem (D.s "tag" n) ["article","h2","h3","p","pre","table","img"]) (walk populated) then [] else [V.p "memo-stub" "This Memo is a stub. No populated memory entries have been saved yet."]) <> map (copy false) populated <> [V.when (not $ A.null emptyIds) $ V.node "aside" [V.cls "memo-unrecorded"] $ [V.text "Unrecorded fields have no saved content yet."] <> map (\id -> V.node "span" [V.id $ "note-" <> id] []) emptyIds]

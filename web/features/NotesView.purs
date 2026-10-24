module Sapiens.Notes (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Traversable (traverse)
import Data.Either (Either(..))
import Data.Foldable (foldl, for_)
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Nullable (toMaybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (try)
import Effect.Class (liftEffect)
import Effect.Exception (message, throw)
import Effect.Exception as Exception
import Sapiens.Runtime
import Sapiens.Text as T

pattern :: String -> String
pattern "yaml" = "(?<string>\"(?:\\\\.|[^\"\\\\])*\"|'(?:''|[^'])*')|(?<comment>(?<!\\S)#[^\\n]*)|(?<key>\\b[A-Za-z_][\\w-]*(?=:\\s|:$))|(?<literal>\\b(?:true|false|null|\\d+(?:\\.\\d+)?)\\b)|(?<punctuation>[{}[\\]:,|>])"
pattern "python" = "(?<string>\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')|(?<comment>#[^\\n]*)|(?<keyword>\\b(?:def|class|import|from|as|return|if|elif|else|for|while|in|is|not|and|or|with|try|except|raise|yield|async|await|pass|lambda)\\b)|(?<literal>\\b(?:True|False|None|\\d+(?:\\.\\d+)?)\\b)"
pattern "haskell" = "(?<string>\"(?:\\\\.|[^\"\\\\])*\")|(?<comment>--[^\\n]*|\\{-[\\s\\S]*?-\\})|(?<keyword>\\b(?:data|type|newtype|where|let|in|case|of|if|then|else|do|module|import|deriving)\\b|::|->|<-|=>)|(?<literal>\\b(?:[A-Z]\\w*|\\d+)\\b)"
pattern "html" = "(?<comment><!--[\\s\\S]*?-->)|(?<string>\"[^\"]*\"|'[^']*')|(?<keyword><\\/?[\\w-]+|\\/?>)|(?<key>\\b[\\w-]+(?=\\s*=))"
pattern _ = ""

highlight :: String -> String -> String
highlight source language
  | language == "yaml" && T.test "[|>][1-9+-]*\\s*(?:#.*)?$" "m" source =
      let result = foldl (\acc line ->
            let indent = CU.length $ T.replace "[^ ].*$" "" "" line
                block = case acc.indent of
                  Just level -> S.trim line == "" || indent > level
                  Nothing -> false
                next = if block then acc.indent else if T.test "[|>][1-9+-]*\\s*(?:#.*)?$" "" line then Just (indent + if T.test "^\\s*-\\s" "" line then 2 else 0) else Nothing
            in {indent:next, lines:A.snoc acc.lines $ if block then "<span class=\"syntax-string\">" <> escape line <> "</span>" else highlight line "yaml-line"})
            {indent:Nothing, lines:[]} (S.split (S.Pattern "\n") source)
      in S.joinWith "\n" result.lines
  | otherwise =
      let kind = if language == "svg" then "html" else if language == "yaml-line" then "yaml" else language
          regex = pattern kind
          labels = case kind of
            "yaml" -> ["string", "comment", "key", "literal", "punctuation"]
            "html" -> ["comment", "string", "keyword", "key"]
            _ -> ["string", "comment", "keyword", "literal"]
          result = foldl (\acc m ->
            let index = fromMaybe 0 $ A.findIndex isJust $ map toMaybe m.groups
                label = fromMaybe "string" $ A.index labels index
            in {output:acc.output <> escape (T.slice acc.cursor m.index source) <> "<span class=\"syntax-" <> label <> "\">" <> escape m.value <> "</span>", cursor:m.index + CU.length m.value})
            {output:"", cursor:0} (if regex == "" then [] else T.matches regex "gm" source)
      in result.output <> escape (CU.drop result.cursor source)

textNode :: String -> Effect Value
textNode text = call (global .! "document") "createTextNode" [value text]

notesWiki :: String -> String -> String -> Value -> Value -> Int -> Effect Value
notesWiki source path owner profile metadata turns = do
  nodes <- readMarkup source
  let sections = A.filter (\node -> int (node .! "nodeType") == 1) nodes
  unless (A.length sections == 3 && A.all identity (A.mapWithIndex (\i node -> field "tagName" node == "SECTION" && field "id" node == string (at i $ map value ["about", "map", "content"])) sections)) $
    throw "Notes.html requires exactly three sections: about, map, content."
  ids <- traverse (\node -> do
    descendants <- qaIn node "[id]"
    pure $ map (field "id") (A.cons node descendants)) sections
  let allIds = A.filter (_ /= "") $ A.concat ids
  unless (A.length (A.nub allIds) == A.length allIds) $ throw "Notes.html section anchors must be unique."
  root <- element "div" "notes-wiki" ""
  let tags = S.split (S.Pattern " ") "section article nav div p span h2 h3 h4 blockquote sup sub pre code a img table thead tbody tfoot tr td th caption ul ol li dl dt dd details summary figure figcaption strong em b i small br hr"
      copy node
        | int (node .! "nodeType") == 3 = textNode $ textOf node
        | int (node .! "nodeType") /= 1 = textNode ""
        | field "localName" node == "svg" = do
            image <- element "img" "" ""
            serializer <- construct (global .! "XMLSerializer") []
            xml <- call serializer "serializeToString" [node]
            label <- getAttr node "aria-label"
            setField image "src" $ "data:image/svg+xml," <> T.encode (string xml)
            setField image "alt" $ if label == "" then "Diagram" else label
            pure image
        | not (A.elem (field "localName" node) tags) = textNode ""
        | otherwise = do
            let tag = field "localName" node
            originalClass <- getAttr node "class"
            let classes = A.filter (flip A.elem ["citation", "permalink", "references", "origin", "backref", "wiki-table", "file-list", "stub-note", "draft-note"]) $ S.split (S.Pattern " ") $ T.replace "\\s+" "g" " " originalClass
            target <- element tag (S.joinWith " " classes) ""
            for_ ["data-memo-name", "data-memo-role", "data-memo-assists"] \name -> do
              present <- call node "hasAttribute" [value name]
              when (boolean present) $ getAttr node name >>= attr target name
            when (tag == "details") do
              open <- call node "hasAttribute" [value "open"]
              set target "open" open
            when (T.test "^[a-z][\\w-]*$" "i" $ field "id" node) $ setField target "id" $ "note-" <> field "id" node
            if tag == "code" then do
              let language = fromMaybe "text" $ A.head (T.matches "^language-(yaml|python|html|svg|haskell)$" "" originalClass) >>= T.group 1
              setField (target .! "dataset") "language" language
              html target $ highlight (textOf node) language
              pure target
            else do
              when (tag == "a") do
                href <- getAttr node "href"
                if T.test "^#[a-z][\\w-]*$" "i" href then setField (target .! "dataset") "noteAnchor" $ "note-" <> CU.drop 1 href
                else case toMaybe $ T.url href ("file://" <> path) of
                  Just address | address.protocol == "file:" -> setField (target .! "dataset") "fileLink" $ T.decode address.pathname
                  Just address | A.elem address.protocol ["http:", "https:"] -> do
                    setField target "href" address.href
                    setField target "className" "chat-link"
                    setField target "target" "_blank"
                    setField target "rel" "noopener noreferrer"
                  _ -> pure unit
                when (boolean (target .! "dataset" .! "noteAnchor") || boolean (target .! "dataset" .! "fileLink")) $ setField target "href" "#" *> attr target "role" "link"
              when (tag == "img") do
                src <- getAttr node "src"
                getAttr node "alt" >>= setField target "alt"
                if T.test "^data:image/(?:png|jpeg|gif|webp|svg\\+xml)[;,]" "i" src then setField target "src" src
                else when (src /= "" && not (T.test "^(?:[a-z]+:|//|/)" "i" src)) do
                  let uri = "/api/" <> (if field "kind" profile == "group" then "groups" else "agents") <> "/" <> T.encode owner <> "/notes?image=" <> T.encode src
                      connections = global .! "window" .! "SapiensConnections"
                  if not (boolean connections) then setField target "src" uri
                  else report do
                    outcome <- try do
                      response <- await $ call connections "fetch" [value uri]
                      unless (boolean $ response .! "ok") $ liftEffect $ throw "Image unavailable"
                      blob <- await $ call response "blob" []
                      liftEffect do
                        url <- call (global .! "URL") "createObjectURL" [blob]
                        let revoke = callback \_ -> call (global .! "URL") "revokeObjectURL" [url]
                        set target "onload" revoke
                        set target "onerror" revoke
                        set target "src" url
                    case outcome of
                      Left _ -> liftEffect $ when (field "alt" target == "") $ setField target "alt" "Image unavailable"
                      Right _ -> pure unit
              for_ ["colspan", "rowspan"] \name -> do
                val <- getAttr node name
                when (T.test "^[1-9]\\d?$" "" val) $ attr target name val
              traverse copy (children node) >>= append target
              pure target
  traverse copy sections >>= append root
  presentMemo root profile (merge [value {path}, metadata]) turns
  codes <- qaIn root "pre > code"
  for_ codes \code -> set (code .! "parentElement" .! "dataset") "language" $ code .! "dataset" .! "language"
  on root "click" false \event -> do
    link <- closest (event .! "target") "[data-note-anchor]"
    when (boolean link) do
      prevent event
      target <- qIn root $ "#" <> field "noteAnchor" (link .! "dataset")
      let expand node = when (boolean node && not (same node root)) do
            when (field "tagName" node == "DETAILS") $ setField node "open" true
            expand $ node .! "parentElement"
      expand target
      when (boolean target) $ void $ call target "scrollIntoView" [value {block:"start"}]
  pure root

memoFacts :: Value -> Effect Value
memoFacts code = do
  let lines = S.split (S.Pattern "\n") $ S.trim $ textOf code
      scalar text = case T.matches "^\"(?:\\\\.|[^\"\\\\])*\"$" "" text of
        [] -> pure text
        _ -> do
          decoded <- Exception.try $ parseE text
          pure $ case decoded of
            Left _ -> text
            Right result -> string result
  if A.null lines || not (A.all (\line -> S.trim line == "" || T.test "^\\s*(?:[\\w-]+\\s*:|[-#] |[ \\t]+\\S)" "" line) lines) then pure null
  else do
    fragment <- element "div" "memo-facts" ""
    let loop index = when (index < A.length lines) do
          let line = fromMaybe "" $ A.index lines index
              match = A.head $ T.matches "^(\\s*)([\\w-]+):\\s*(.*)$" "" line
          p <- element "p" "" ""
          next <- case match of
            Nothing -> setField p "textContent" (S.trim line) $> (index + 1)
            Just m -> do
              let label = T.replace "_" "g" " " $ fromMaybe "" $ T.group 2 m
                  val = fromMaybe "" $ T.group 3 m
                  indent = CU.length $ fromMaybe "" $ T.group 1 m
              strong <- element "strong" "" $ label <> ": "
              append p [strong]
              if T.test "^[|>][+-]?$" "" val then do
                let block = A.takeWhile (\text -> S.trim text == "" || CU.length (T.replace "\\S.*$" "" "" text) > indent) $ A.drop (index + 1) lines
                    text = S.joinWith (if CU.take 1 val == ">" then " " else "\n") $ map S.trim block
                textNode text >>= \node -> append p [node]
                pure $ index + 1 + A.length block
              else scalar val >>= textNode >>= \node -> append p [node] $> (index + 1)
          append fragment [p]
          loop next
    loop 0
    pure fragment

presentMemo :: Value -> Value -> Value -> Int -> Effect Unit
presentMemo root profile metadata turnCount = do
  about <- qIn root "#note-about"
  mapNode <- qIn root "#note-map"
  content <- qIn root "#note-content"
  let displayName = string $ about .! "dataset" .! "memoName" <||> profile .! "name" <||> value "Sapi"
      label id = let words = T.replace "[-_]" "g" " " $ T.replace "^note-" "" "" id
                 in S.toUpper (CU.take 1 words) <> CU.drop 1 words
  nodes <- qaIn content "article,details"
  emptyIds <- foldl (\action node -> do
    ids <- action
    snippets <- qaIn node "pre > code"
    rich <- qIn node "img,a,p,table,blockquote"
    let empty = not (A.null snippets) && not (boolean rich) && A.all (\code -> A.all (\line -> S.trim line == "" || T.test "^\\s*[\\w-]+:\\s*(?:[\"']?\\*\\*\\*[\"']?|\\{\\}|\\[\\])\\s*$" "" line) $ S.split (S.Pattern "\n") $ S.trim $ textOf code) snippets
    if not empty then pure ids else do
      children_ <- qaIn node "[id]"
      void $ call node "remove" []
      pure $ A.nub $ ids <> A.filter (_ /= "") (map (field "id") $ A.cons node children_)) (pure []) nodes
  unless (A.null emptyIds) do
    stub <- element "aside" "memo-unrecorded" "Unrecorded fields have no saved content yet."
    for_ emptyIds \id -> do
      anchor <- element "span" "" ""
      setField anchor "id" id
      append stub [anchor]
    append content [stub]
  qaIn root "details" >>= flip for_ (\node -> do
    section <- element "div" "" ""
    set section "id" $ node .! "id"
    append section $ children node
    void $ call node "replaceWith" [section])
  qaIn root "summary" >>= flip for_ (\node -> element "h3" "" (textOf node) >>= \heading -> void $ call node "replaceWith" [heading])
  qaIn root "pre > code[data-language=\"yaml\"]" >>= flip for_ (\code -> do
    facts <- memoFacts code
    when (boolean facts) $ void $ call (code .! "parentElement") "replaceWith" [facts])
  qaIn about ".memo-facts strong" >>= flip for_ (\node -> void $ call node "remove" [])
  named <- qaIn mapNode "[data-note-anchor]"
  qaIn content ":scope > article" >>= flip for_ (\article -> do
    title <- qIn article ":scope > h2"
    unless (boolean title) do
      let found = find (\a -> field "noteAnchor" (a .! "dataset") == field "id" article) named
      heading <- element "h2" "" $ if boolean found then textOf found else label (field "id" article)
      void $ call article "prepend" [heading])
  toc <- element "nav" "memo-toc" ""
  set toc "id" $ mapNode .! "id"
  attr toc "aria-label" "Contents"
  list <- element "ol" "" ""
  headings <- qaIn content "h2"
  let entries = if A.null headings then map (\a -> {id:field "noteAnchor" $ a .! "dataset", text:textOf a}) named else
        map (\heading -> {id:string $ heading .! "id" <||> heading .! "parentElement" .! "id"
          , text:join $ map textOf $ A.filter (\node -> int (node .! "nodeType") == 3 || not (T.test "(?:^|\\s)permalink(?:\\s|$)" "" $ field "className" node)) $ children heading}) headings
  void $ foldl (\action entry -> do
    seen <- action
    target <- if entry.id == "" then pure null else qIn root $ "#" <> entry.id
    if entry.id == "" || A.elem entry.id emptyIds || A.elem entry.id seen || not (boolean target) then pure seen else do
      li <- element "li" "" ""
      a <- element "a" "" entry.text
      setField a "href" $ "#" <> entry.id
      setField (a .! "dataset") "noteAnchor" entry.id
      append li [a]
      append list [li]
      pure $ A.snoc seen entry.id) (pure []) entries
  if A.length (array $ list .! "children") > 1 then do
    title <- element "strong" "" "Contents"
    append toc [title,list]
    void $ call mapNode "replaceWith" [toc]
  else void $ call mapNode "remove" []
  header <- element "header" "memo-header" ""
  dates <- element "p" "memo-meta" ""
  let history label_ timestamp author = do
        row <- element "span" "" $ label_ <> " "
        if timestamp /= "" then do
          date_ <- construct (global .! "Date") [value timestamp]
          valid <- call date_ "getTime" []
          finite <- call (global .! "Number") "isFinite" [valid]
          if boolean finite then do
            time <- element "time" "" ""
            setField time "dateTime" timestamp
            day <- call date_ "toLocaleDateString" [value "en-GB", value {day:"numeric", month:"short", year:"numeric"}]
            clock <- call date_ "toLocaleTimeString" [value "en-GB", value {hour:"2-digit", minute:"2-digit", hour12:false}]
            formatter <- call (global .! "Intl") "DateTimeFormat" []
            options <- call formatter "resolvedOptions" []
            zone <- if field "timeZone" options == "Asia/Dubai" then pure "GST" else do
              text <- call date_ "toLocaleTimeString" [value "en-GB", value {timeZoneName:"short"}]
              pure $ fromMaybe "" $ A.last $ S.split (S.Pattern " ") $ string text
            setField time "textContent" $ string day <> " · " <> string clock <> " " <> zone
            append row [time]
          else textNode "not recorded" >>= \node -> append row [node]
        else textNode "not recorded" >>= \node -> append row [node]
        textNode " by " >>= \node -> append row [node]
        by <- element "span" "memo-actor" $ if author == "" then "unrecorded actor" else author
        append row [by]
        append dates [row]
  history "Last modified at" (field "modified_at" metadata) (field "modified_by" metadata)
  history "Created at" (field "created_at" metadata) (field "created_by" metadata)
  append header [dates]
  void $ call root "prepend" [header]
  box <- element "aside" "memo-infobox" ""
  attr box "aria-label" $ displayName <> " at a glance"
  identityNode <- element "div" "memo-identity" ""
  face <- element "span" "memo-avatar" $ "(" <> string (profile .! "face" <||> value "◠‿◠") <> ")"
  style face "background-color" $ if T.test "^#[a-f0-9]{6}$" "i" (field "color" profile) then field "color" profile else "#d8e5f4"
  name <- element "strong" "" displayName
  append identityNode [face,name]
  append box [identityNode]
  table <- element "table" "" ""
  for_ [Tuple "Full name" (if displayName /= field "name" profile then field "name" profile else "")
       ,Tuple "Role" (string $ about .! "dataset" .! "memoRole" <||> profile .! "role")
       ,Tuple "Assists" (field "memoAssists" $ about .! "dataset")
       ,Tuple "History" (show turnCount <> " recorded turns")
       ,Tuple (if field "kind" profile == "group" then "Group ID" else "Sapi ID") (field "id" profile)] \(Tuple key val) -> when (val /= "") do
    tr <- element "tr" "" ""
    th <- element "th" "" key
    td <- element "td" (if T.test " ID$" "" key then "memo-id" else "") val
    append tr [th,td]
    append table [tr]
  append box [table]
  workspace <- element "div" "memo-workspace" ""
  workspaceLabel <- element "strong" "" "Workspace"
  workspacePath <- element "code" "" $ string $ metadata .! "workspace" <||> value (T.replace "/[^/]+$" "" "" $ field "path" metadata) <||> value "Not recorded"
  append workspace [workspaceLabel,workspacePath]
  append box [workspace]
  void $ call about "prepend" [box]
  setField about "className" "memo-lead"
  populated <- qIn content "article,h2,h3,p,pre,table,img"
  unless (boolean populated) do
    p <- element "p" "memo-stub" "This Memo is a stub. No populated memory entries have been saved yet."
    void $ call content "prepend" [p]

notesInfo :: String -> Effect Value
notesInfo id = do
  profile <- exec "agent" [value id]
  live <- read "live"
  pure $ if field "kind" profile == "group" then profile .! "notes" else live .! "orchestration" .! id .! "notes"

renderNotes :: Value -> Effect Unit
renderNotes host = do
  state <- read "state"
  let id = field "selected" state
  info <- notesInfo id
  profile <- exec "agent" [value id]
  live <- read "live"
  let turns = A.length $ A.filter (\turn -> field (if field "kind" profile == "group" then "group" else "agent") turn == id) $ items "turns" live
      key = stringify $ value [value id, info .! "revision", profile .! "name", profile .! "role", profile .! "face", profile .! "color", value turns]
      data_ = host .! "dataset"
  wiki <- qIn host ".notes-wiki"
  unless ((field "notes" data_ == key && boolean wiki) || field "notesPending" data_ == key) do
    let previousScroll = if field "notesOwner" data_ == id then number (wiki .! "scrollTop") else 0.0
    when (not (boolean wiki) || field "notesOwner" data_ /= id) $ replaceChildren host []
    setField data_ "notesPending" key
    setField data_ "notesOwner" id
    report do
      outcome <- try do
        row <- fetch $ "/api/" <> (if field "kind" profile == "group" then "groups" else "agents") <> "/" <> id <> "/notes"
        liftEffect do
          latest <- read "state"
          latestInfo <- notesInfo id
          when (field "selected" latest == id && A.elem (field "panel" latest) ["notes", "work"] && boolean (host .! "isConnected") && same (latestInfo .! "revision") (info .! "revision") && field "notesPending" data_ == key) do
            next <- notesWiki (field "content" row) (field "path" row) id profile (row .! "metadata" <||> info) turns
            replaceChildren host [next]
            setField data_ "notes" key
            setField next "scrollTop" previousScroll
      liftEffect do
        latest <- read "state"
        case outcome of
          Left error | field "selected" latest == id && A.elem (field "panel" latest) ["notes", "work"] && field "notesPending" data_ == key -> setField host "textContent" $ message error
          _ -> pure unit
        when (field "notesPending" data_ == key) $ remove data_ "notesPending"

main :: Effect Unit
main = do
  register "highlightNotes" \args -> pure $ value $ highlight (string $ at 0 args) (string $ at 1 args <||> value "yaml")
  register "notesWiki" \args -> notesWiki (string $ at 0 args) (string $ at 1 args) (string $ at 2 args) (at 3 args) (at 4 args) (int $ at 5 args)
  register "notesInfo" \args -> notesInfo $ string $ at 0 args
  register "renderNotes" \args -> renderNotes (at 0 args) $> null

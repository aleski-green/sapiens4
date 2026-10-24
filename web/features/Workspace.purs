module Sapiens.Workspace (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Int as Int
import Data.Number as Number
import Data.String as S
import Effect (Effect)
import Effect.Aff (Aff, try)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Sapiens.Async (toPromise)
import Sapiens.Runtime
import Sapiens.Text as T

receiveWorkspaces :: Value -> Effect Unit
receiveWorkspaces prefs = do
  revision <- read "workspaceRevision"
  when (number (prefs .! "workspace_revision") > number revision) do
    write "workspaceRevision" $ prefs .! "workspace_revision"
    state <- read "state"
    set state "workspaces" $ prefs .! "workspaces" <||> value {}
    fire "syncWorkspace" []

destination :: String -> Value
destination text = if T.test "^(https?:|file:|about:)" "i" text then value {url:text} else value {path:text}

nativeAvailable :: Effect Boolean
nativeAvailable = do
  window <- getE global "window"
  pure $ boolean (window .! "webkit" .! "messageHandlers" .! "browser") &&
    field "location" (window .! "SapiensConnections" .! "active") /= "Remote"

bookmarks :: Value -> Array Value
bookmarks state = items "bookmarks" $ state .! "workspaces" .! field "selected" state

tabBookmark :: Value -> Value -> Value
tabBookmark state tab = find (\b -> field "url" b == field "url" tab &&
  field "id" (find (\s -> field "id" s == field "tab_id" b && field "url" s == field "url" b) tabs <||>
    find (\s -> field "url" s == field "url" b) tabs) == field "id" tab) (bookmarks state)
  where tabs = items "tabs" state

starButton :: Value -> Value -> String
starButton state tab =
  let saved = boolean $ tabBookmark state tab
  in "<button class=\"tab-star\" data-star-tab=\"" <> escape (field "id" tab) <> "\" aria-label=\"" <>
    (if saved then "Unbookmark" else "Bookmark") <> " " <> escape (field "title" tab) <> "\" aria-pressed=\"" <> show saved <>
    "\" " <> (if field "url" tab == "about:blank" then "disabled" else "") <> ">" <> (if saved then "★" else "☆") <> "</button>"

layoutTabs :: Effect Unit
layoutTabs = do
  state <- read "state"
  host <- q "#browser-tabs"
  overflow <- q "#browser-overflow"
  limit <- exec "paneLimit" []
  let rows = array $ host .! "children"
      count = show $ A.length $ items "tabs" state
  for_ rows \row -> setField row "hidden" false
  setField host "scrollLeft" 0
  attr overflow "aria-label" $ "All " <> count <> " open tabs"
  if int limit < 3 then do
    for_ rows \row -> do
      active <- call (row .! "classList") "contains" [value "active"]
      setField row "hidden" $ not $ boolean active
    setField overflow "hidden" $ A.length (items "tabs" state) < 2
    setField overflow "textContent" $ "⌄ " <> count
  else do
    setField overflow "hidden" true
    setField overflow "hidden" $ number (host .! "scrollWidth") <= number (host .! "clientWidth") + 1.0
    setField overflow "textContent" $ "› " <> count
    active <- qIn host ".active"
    let visible = A.take (max 1 $ Int.floor $ (number (host .! "clientWidth") + 3.0) / 134.0) rows
        shown = if boolean active && not (A.any (same active) visible) then A.snoc (A.take (A.length visible - 1) visible) active else visible
    for_ rows \row -> setField row "hidden" $ not $ A.any (same row) shown

setBrowserMenu :: String -> Effect Unit
setBrowserMenu mode = do
  prop "#browser-menu" "hidden" $ mode == ""
  prop "#browser-options" "hidden" $ mode /= "options"
  prop "#browser-all-tabs" "hidden" $ mode /= "tabs"
  q "#workspace-menu" >>= \node -> attr node "aria-expanded" $ show $ mode == "options"
  q "#browser-overflow" >>= \node -> attr node "aria-expanded" $ show $ mode == "tabs"
  syncNativeBrowser

renderTabs :: Effect Unit
renderTabs = do
  fire "renderPanes" []
  state <- read "state"
  let tabs = items "tabs" state
      rows xs = stringMap xs \tab ->
        "<div class=\"workspace-tab " <> (if field "id" tab == field "activeTab" state then "active" else "") <> "\">" <> starButton state tab <>
        "<button class=\"tab-select\" data-tab=\"" <> escape (field "id" tab) <> "\" aria-pressed=\"" <> show (field "id" tab == field "activeTab" state) <>
        "\" title=\"" <> escape (string $ tab .! "path" <||> tab .! "url") <> "\">" <> escape (string $ tab .! "title" <||> value "New tab") <>
        "</button><button class=\"tab-close\" data-close-tab=\"" <> escape (field "id" tab) <> "\" aria-label=\"Close " <> escape (field "title" tab) <> "\">×</button></div>"
      sorted = rows $ A.sortBy (\a b -> compare (boolean $ tabBookmark state b) (boolean $ tabBookmark state a)) tabs
      saved = stringMap (bookmarks state) \b -> "<div class=\"bookmark-row\"><button data-bookmark-open=\"" <> escape (field "url" b) <> "\">★ " <> escape (field "title" b) <>
        "</button><button data-bookmark-remove=\"" <> escape (field "id" b) <> "\" aria-label=\"Remove " <> escape (field "title" b) <> " bookmark\">×</button></div>"
  putHTML "#browser-tabs" $ if sorted == "" then "<div class=\"workspace-tab active\"><button class=\"tab-select\" data-action=\"new-tab\" aria-pressed=\"true\">New tab</button></div>" else sorted
  putHTML "#browser-all-tabs" $ "<div class=\"browser-menu-label\">Open tabs · " <> show (A.length tabs) <> "</div>" <> rows tabs
  putHTML "#browser-bookmarks" $ if saved == "" then "<p>No bookmarks yet.</p>" else saved
  layoutTabs

refreshPreview :: Aff Unit
refreshPreview = do
  native <- liftEffect nativeAvailable
  unless native do
    state <- liftEffect $ read "state"
    host <- liftEffect $ q "#workspace-content"
    previous <- liftEffect $ read "workspacePreview"
    let tab = find (\t -> field "id" t == field "activeTab" state) $ items "tabs" state
        key = stringify $ value [state .! "selected", tab .! "id", tab .! "path", tab .! "command" .! "seq"]
    when (field "key" previous /= key) $ liftEffect do
      write "workspacePreview" {key, checked:0.0, pending:false}
      replaceChildren host []
      if not (boolean $ tab .! "path") then setField host "textContent" $
        if boolean tab && field "url" tab /= "about:blank" then "Open Sapiens4 desktop to browse this web page." else "Open a URL or file to get started."
      else do
        pre <- element "pre" "workspace-text" "Loading…"
        attr pre "aria-label" $ field "title" tab
        append host [pre]
    when (boolean (tab .! "path") && boolean (state .! "panes" .! "workspace")) do
      pre <- liftEffect $ qIn host ".workspace-text"
      current <- liftEffect $ read "workspacePreview"
      limit <- liftEffect $ exec "paneLimit" []
      timestamp <- liftEffect now
      liftEffect do
        style pre "font-size" $ show ((if int limit < 3 then 12.6 else 13.0) * number (tab .! "zoom" <||> value 1)) <> "px"
        prop "#browser-status" "textContent" ""
      unless (boolean (current .! "pending") || timestamp - number (current .! "checked") < 2000.0) do
        liftEffect do
          setField current "pending" true
          setField current "checked" timestamp
        result <- try $ fetch $ "/api/" <> ownerType (field "selected" state) <> "/" <> T.encode (field "selected" state) <> "/browser/" <> T.encode (field "id" tab) <> "/content"
        liftEffect do
          latest <- read "workspacePreview"
          when (same current latest) do
            let content = case result of
                  Right data_ -> field "content" data_
                  Left error -> message error
            when (textOf pre /= content) $ setField pre "textContent" content
          setField current "pending" false

ownerType :: String -> String
ownerType owner = if T.test "^group_" "" owner then "groups" else "agents"

renderWorkspace :: Effect Unit
renderWorkspace = do
  fire "syncWorkspace" []
  state <- read "state"
  owner <- read "workspaceOwner"
  ownerLabel <- exec "mention" [owner]
  putHTML "#workspace-owner" $ string ownerLabel <> "<span>’s browser</span>"
  editing <- read "editingAddress"
  input <- q "#browser-address"
  let tab = find (\t -> field "id" t == field "activeTab" state) $ items "tabs" state
  prop "#browser-address-form" "hidden" $ boolean tab && field "url" tab /= "about:blank" && not (same editing (tab .! "id"))
  unless (same (global .! "document" .! "activeElement") input) $ setField input "value" $ string $
    tab .! "path" <||> (if field "url" tab == "about:blank" then value "" else tab .! "url")
  prop "#browser-zoom" "textContent" $ show (Int.round $ number (tab .! "zoom" <||> value 1) * 100.0) <> "%"
  prop "#browser-status" "textContent" $ string $ tab .! "error" <||> value (if boolean (tab .! "loading") then "Loading…" else "")
  buttons <- qa "[data-browser-action]"
  for_ buttons \b -> setField b "disabled" $ not (boolean tab) ||
    (field "browserAction" (b .! "dataset") == "back" && not (boolean $ tab .! "can_back")) ||
    (field "browserAction" (b .! "dataset") == "forward" && not (boolean $ tab .! "can_forward"))
  native <- nativeAvailable
  if native then prop "#workspace-content" "textContent" $ if boolean tab then "" else "Open a URL or file to get started."
  else report refreshPreview
  syncNativeBrowser

syncNativeBrowser :: Effect Unit
syncNativeBrowser = do
  let bridge = global .! "window" .! "webkit" .! "messageHandlers" .! "browser"
  when (boolean bridge) do
    native <- nativeAvailable
    if not native then void $ call bridge "postMessage" [value {workspaces:{}, owner:"", active:null, visible:false}]
    else do
      state <- read "state"
      host <- q "#workspace-content"
      rect <- call host "getBoundingClientRect" []
      workspace <- q ".workspace"
      palette <- call global "getComputedStyle" [workspace]
      panel <- q "#workspace-panel"
      modal <- q "#modal"
      menu <- q "#browser-menu"
      dialog <- q "#corpora-dialog"
      notice <- q "#corpora-notice"
      corpora <- q "#corpora-menu"
      status <- q "#corpora-status-menu"
      background <- call palette "getPropertyValue" [value "--sapi-white"]
      foreground <- call palette "getPropertyValue" [value "--sapi-ink"]
      caption <- call palette "getPropertyValue" [value "--sapi-bg"]
      void $ call bridge "postMessage" [value
        {workspaces:state .! "workspaces", owner:state .! "selected", active:state .! "activeTab"
        , visible:not (boolean $ panel .! "hidden") && not (boolean $ modal .! "open") && boolean (menu .! "hidden") &&
            not (boolean $ dialog .! "open") && not (boolean $ notice .! "open") &&
            (not (boolean corpora) || boolean (corpora .! "hidden")) && (not (boolean status) || boolean (status .! "hidden"))
        , dark:field "theme" (global .! "document" .! "documentElement" .! "dataset") == "dark"
        , background:S.trim $ string background, foreground:S.trim $ string foreground, captionBackground:S.trim $ string caption
        , rect:{x:rect .! "x", y:rect .! "y", width:rect .! "width", height:rect .! "height"}}]

browserAction :: String -> Value -> String -> Aff Boolean
browserAction action fields owner = do
  result <- try do
    void $ request ("/api/" <> ownerType owner <> "/" <> owner <> "/control") "POST" $ merge [value {op:"workspace_" <> action}, fields]
    snapshot <- fetch "/api/state"
    liftEffect do
      receiveWorkspaces $ snapshot .! "preferences"
      when (A.elem action ["open", "focus", "close", "back", "forward", "reload"]) do
        setBrowserMenu ""
        fire "showPane" [value "workspace"]
      fire "renderPanes" []
      renderTabs
      renderWorkspace
      fire "save" []
  case result of
    Right _ -> pure true
    Left error -> liftEffect (fire "toast" [value $ message error]) $> false

openNewTab :: Aff Unit
openNewTab = do
  state <- liftEffect $ read "state"
  let owner = field "selected" state
  opened <- browserAction "open" (value {url:"about:blank"}) owner
  latest <- liftEffect $ read "state"
  when (opened && field "selected" latest == owner) $ liftEffect do
    prop "#browser-address" "value" ""
    q "#browser-address" >>= focus

main :: Effect Unit
main = do
  bootstrap <- read "bootstrap"
  write "workspaceRevision" $ bootstrap .! "preferences" .! "workspace_revision" <||> value 0
  write "editingAddress" null
  write "workspacePreview" null
  register "receiveWorkspaces" \args -> receiveWorkspaces (at 0 args) $> null
  register "browserDestination" \args -> pure $ destination $ string $ at 0 args
  register "starButton" \args -> read "state" <#> \state -> value $ starButton state (at 0 args)
  for_ [ {name:"layoutTabs", action:layoutTabs}, {name:"renderTabs", action:renderTabs}
       , {name:"renderWorkspace", action:renderWorkspace}, {name:"syncNativeBrowser", action:syncNativeBrowser} ] \entry ->
    register entry.name \_ -> entry.action $> null
  register "nativeWorkspaceAvailable" \_ -> value <$> nativeAvailable
  register "setBrowserMenu" \args -> setBrowserMenu (string $ at 0 args) $> null
  registerAsync "refreshWorkspacePreview" \_ -> refreshPreview $> null
  registerAsync "openNewTab" \_ -> openNewTab $> null
  registerAsync "browserAction" \args -> do
    state <- liftEffect $ read "state"
    value <$> browserAction (string $ at 0 args) (at 1 args) (string $ at 2 args <||> state .! "selected")
  register "mountWorkspace" \_ -> mount $> null

mount :: Effect Unit
mount = do
  initial <- toPromise $ pure null
  write "browserReports" initial
  let window = global .! "window"
      document = global .! "document"
  set window "sapiensBrowserEvent" $ callback \args -> do
    let data_ = at 0 args
        connections = window .! "SapiensConnections"
        generation = connections .! "generation"
    native <- nativeAvailable
    state <- read "state"
    when (native && not (boolean $ connections .! "busy") && A.any (\a -> field "id" a == field "owner" data_) (items "agents" state)) do
      previous <- read "browserReports"
      pending <- toPromise do
        result <- try do
          void $ await $ pure previous
          when (same generation (connections .! "generation")) do
            let owner = field "owner" data_
            if boolean (data_ .! "open") then void $ browserAction "open" (value {url:data_ .! "open"}) owner
            else if boolean (data_ .! "file") then void $ browserAction "open" (value {path:data_ .! "file"}) owner
            else if boolean (data_ .! "action") then void $ browserAction (field "action" data_) (data_ .! "fields") owner
            else do
              void $ request ("/api/" <> ownerType owner <> "/" <> owner <> "/browser") "POST" data_
              snapshot <- fetch "/api/state"
              liftEffect $ receiveWorkspaces (snapshot .! "preferences") *> renderTabs *> renderWorkspace
        case result of
          Left error -> liftEffect $ fire "toast" [value $ message error]
          Right _ -> pure unit
        pure null
      write "browserReports" pending
    pure null
  q "#browser-address-form" >>= \form -> on form "submit" false \event -> do
    prevent event
    input <- q "#browser-address"
    let text = S.trim $ field "value" input
    when (text /= "") do
      void $ call input "blur" []
      state <- read "state"
      report do
        opened <- browserAction "open" (merge [destination text, if boolean (state .! "activeTab") then value {id:state .! "activeTab"} else value {}]) (field "selected" state)
        when opened $ liftEffect $ write "editingAddress" null *> renderWorkspace
  q "#add-tab" >>= \node -> on node "click" false (const $ report openNewTab)
  q "#open-file" >>= \node -> on node "click" false \_ -> do
    state <- read "state"
    live <- read "live"
    selected <- exec "selected" []
    let directory = if field "kind" selected == "group" then field "workspace" selected else
          T.replace "[\\\\/][^\\\\/]+$" "" "" $ field "path" (live .! "orchestration" .! field "selected" state .! "notes")
    setBrowserMenu ""
    native <- nativeAvailable
    if native then void $ call (window .! "webkit" .! "messageHandlers" .! "browser") "postMessage" [value {pickFile:true, owner:state .! "selected", directory}]
    else do
      write "editingAddress" $ state .! "activeTab"
      renderWorkspace
      prop "#browser-address" "value" $ directory <> "/"
      q "#browser-address" >>= focus
  on document "click" false \event -> do
    let target = event .! "target"
    inside <- closest target ".browser-menu,.browser-tabs-wrap"
    unless (boolean inside) $ setBrowserMenu ""
    button <- closest target "button"
    when (boolean button) do
      state <- read "state"
      let d = button .! "dataset"
          owner = field "selected" state
          perform action fields = report $ void $ browserAction action fields owner
          active = find (\t -> field "id" t == field "activeTab" state) $ items "tabs" state
      when (A.elem (field "id" button) ["workspace-menu", "browser-overflow"]) do
        let mode = if field "id" button == "workspace-menu" then "options" else "tabs"
        expanded <- getAttr button "aria-expanded"
        setBrowserMenu $ if expanded == "true" then "" else mode
        menu <- q "#browser-menu"
        unless (boolean $ menu .! "hidden") $ q (if mode == "options" then "#browser-options button:not(:disabled)" else "#browser-all-tabs button:not(:disabled)") >>= focus
      when (has "editAddress" d) do
        write "editingAddress" $ state .! "activeTab"
        setBrowserMenu ""
        renderWorkspace
        input <- q "#browser-address"
        focus input
        void $ call input "select" []
      when (boolean $ d .! "starTab") do
        let tab = find (\t -> field "id" t == field "starTab" d) $ items "tabs" state
            saved = tabBookmark state tab
        when (boolean tab) $ perform (if boolean saved then "unbookmark" else "bookmark") $ value {id:saved .! "id" <||> tab .! "id"}
      when (boolean $ d .! "browserAction") $ perform (field "browserAction" d) (value {})
      when (boolean (d .! "zoom") && boolean active) do
        let factor = if field "zoom" d == "reset" then 1.0 else max 0.25 $ min 5.0 $ Number.round ((number (active .! "zoom" <||> value 1) + number (d .! "zoom")) * 100.0) / 100.0
        perform "zoom" $ value {factor}
      when (boolean $ d .! "bookmarkOpen") do
        let tab = find (\t -> field "url" t == field "bookmarkOpen" d) $ items "tabs" state
        perform (if boolean tab then "focus" else "open") $ if boolean tab then value {id:tab .! "id"} else value {url:d .! "bookmarkOpen"}
      when (boolean $ d .! "bookmarkRemove") $ perform "unbookmark" $ value {id:d .! "bookmarkRemove"}
  on document "keydown" false \event -> do
    state <- read "state"
    menu <- q "#browser-menu"
    when (field "key" event == "Escape" && not (boolean $ menu .! "hidden")) do
      setBrowserMenu ""
      q "#workspace-menu" >>= focus
    modal <- q "#modal"
    when ((boolean (event .! "metaKey") || boolean (event .! "ctrlKey")) && S.toLower (field "key" event) == "l" && boolean (state .! "panes" .! "workspace") && not (boolean $ modal .! "open")) do
      prevent event
      if boolean (state .! "activeTab") then q "[data-edit-address]" >>= \node -> void $ call node "click" [] else report openNewTab
  for_ ["#workspace-content", ".browser-tabs-wrap"] \selector -> q selector >>= \node -> void $ observe "ResizeObserver" node (value {}) (layoutTabs *> syncNativeBrowser)
  void $ observe "MutationObserver" (document .! "documentElement") (value {attributes:true,attributeFilter:["data-theme"]}) syncNativeBrowser
  for_ ["#modal", "#corpora-menu", "#corpora-status-menu", "#corpora-dialog", "#corpora-notice"] \selector -> do
    node <- q selector
    when (boolean node) $ void $ observe "MutationObserver" node (value {attributes:true,attributeFilter:["hidden", "open"]}) syncNativeBrowser
  on window "resize" false $ const syncNativeBrowser
  on window "scroll" true $ const syncNativeBrowser

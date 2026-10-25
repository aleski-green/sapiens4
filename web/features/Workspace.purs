module Sapiens.Workspace where

import Prelude
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Int as I
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Libs4.Browser as B
import Sapiens.Action (Action(..))
import Sapiens.Data as D
import Sapiens.Html as V
import Sapiens.Model as M
import Sapiens.Navigation as N
import Sapiens.Text as T

native :: M.Model -> Boolean
native m = D.b "native" m.env && D.s "location" (M.activeRecord m) /= "Remote"

bookmarks :: M.Model -> Array Json
bookmarks m = D.arr $ D.at [m.selected,"bookmarks"] m.workspaces

bookmark :: M.Model -> Json -> Json
bookmark m tab = fromMaybe D.null $ A.find (\b -> D.s "url" b == D.s "url" tab && D.s "id" (fromMaybe (fromMaybe D.null $ A.find (( _ == D.s "url" b) <<< D.s "url") (M.tabs m)) $ A.find (\t -> D.s "id" t == D.s "tab_id" b && D.s "url" t == D.s "url" b) (M.tabs m)) == D.s "id" tab) $ bookmarks m

view :: M.Model -> V.Html
view m = V.node "main" [V.cls "workspace",V.id "workspace-panel",V.label "Agent workspace",V.hidden $ not $ A.elem N.Workspace $ N.visiblePanes (N.limit m.env) (D.valid tab) m.panes]
  [V.div "browser-tabs-wrap"
    [V.node "div" [V.id "browser-tabs",V.cls "browser-tabs",V.label "Workspace tabs"] $ if A.null tabs then [V.div "workspace-tab active" [V.button "tab-select" "New tab" newTab]] else map (tabView false) $ A.sortBy (\a b -> compare (D.valid $ bookmark m b) (D.valid $ bookmark m a)) tabs
    ,V.node "button" [V.id "browser-overflow",V.label $ "All " <> show (A.length tabs) <> " open tabs",V.hidden $ A.length tabs < 2,V.attr "aria-expanded" $ show $ m.menu == Just "browser-tabs",V.click $ Menu "browser-tabs"] [V.text $ "⌄ " <> show (A.length tabs)]
    ,V.node "button" [V.id "add-tab",V.cls "add-tab",V.label "Add workspace tab",V.click newTab] [V.text "＋"]
    ,V.node "button" [V.id "workspace-menu",V.cls "icon-button",V.label "Workspace options",V.attr "aria-expanded" $ show $ m.menu == Just "browser-options",V.click $ Menu "browser-options"] [V.text "···"]]
  ,V.node "form" [V.id "browser-address-form",V.cls "browser-address-bar",V.hidden $ D.valid tab && D.s "url" tab /= "about:blank" && not m.addressOpen,V.submit OpenAddress]
    [V.node "input" [V.id "browser-address",V.label "URL or file path",V.attr "placeholder" "URL or file path",V.attr "autocomplete" "off",V.bool "spellcheck" false,V.value m.address,V.input Address] [],V.node "button" [V.attr "type" "submit",V.label "Open address"] [V.text "→"]]
  ,V.node "div" [V.id "browser-menu",V.cls "browser-menu",V.attr "role" "dialog",V.label "Workspace options",V.hidden $ not $ A.elem m.menu [Just "browser-options",Just "browser-tabs"]]
    [V.node "div" [V.id "browser-options",V.hidden $ m.menu /= Just "browser-options"]
      [V.div "workspace-owner" [T.mention m m.selected,V.node "span" [] [V.text "’s browser"]]
      ,V.button "" "URL or file path…" EditAddress,V.button "" "Open file…" OpenFile
      ,V.div "browser-menu-row" $ map (\(Tuple action caption) -> V.node "button" [V.disabled $ not (D.valid tab) || (action == "back" && not (D.b "can_back" tab)) || (action == "forward" && not (D.b "can_forward" tab)),V.click $ Browser action D.empty] [V.text caption]) [Tuple "back" "← Back",Tuple "forward" "Forward →",Tuple "reload" "Reload"]
      ,V.div "browser-menu-row" [V.node "span" [] [V.text "Zoom"],zoomButton "Zoom out" "−" (max 0.25 $ zoom-0.1),zoomButton "Reset zoom" (show (I.round $ zoom*100.0) <> "%") 1.0,zoomButton "Zoom in" "＋" (min 5.0 $ zoom+0.1)]
      ,V.div "browser-menu-label" [V.text "Bookmarks"],V.node "div" [V.id "browser-bookmarks"] $ if A.null (bookmarks m) then [V.p "" "No bookmarks yet."] else map bookmarkRow (bookmarks m)]
    ,V.node "div" [V.id "browser-all-tabs",V.hidden $ m.menu /= Just "browser-tabs"] $ [V.div "browser-menu-label" [V.text $ "Open tabs · " <> show (A.length tabs)]] <> map (tabView true) tabs
    ,V.node "span" [V.id "browser-status",V.attr "role" "status"] [V.text $ D.fallback (if D.b "loading" tab then "Loading…" else "") $ D.fallback (D.s "error" tab) m.browserError]]
  ,V.node "div" [V.id "workspace-content",V.cls "workspace-content"] $ if native m then [V.text $ if D.valid tab then "" else "Open a URL or file to get started."] else
      if D.s "path" tab == "" then [V.text $ if D.valid tab && D.s "url" tab /= "about:blank" then "Open Sapiens4 desktop to browse this web page." else "Open a URL or file to get started."] else [V.node "pre" [V.cls "workspace-text",V.label $ D.s "title" tab,V.style $ "font-size:" <> show ((if N.limit m.env < 3 then 12.6 else 13.0) * zoom) <> "px"] [V.text $ case m.preview of
        M.Ready _ value -> D.s "content" value
        M.Loading _ (Just value) -> D.s "content" value
        M.Failed _ error -> error
        _ -> "Loading…"]]
  ,V.node "footer" [V.cls "workspace-footer"] [V.link "https://sapiens4.ai" "sapiens4.ai ↗"]]
  where
  tabs = M.tabs m
  tab = M.activeTab m
  zoom = if D.n "zoom" tab > 0.0 then D.n "zoom" tab else 1.0
  newTab = Browser "open" $ D.obj [Tuple "url" $ D.text "about:blank"]
  zoomButton caption glyph factor = V.node "button" [V.label caption,V.click $ Browser "zoom" $ D.obj [Tuple "factor" $ D.number factor]] [V.text glyph]
  tabView all t =
    let active = D.s "id" t == D.s "id" tab
        saved = bookmark m t
    in V.node "div" [V.cls $ "workspace-tab " <> if active then "active" else "",V.hidden $ not all && N.limit m.env < 3 && not active]
      [V.node "button" [V.cls "tab-star",V.label $ (if D.valid saved then "Unbookmark " else "Bookmark ") <> D.s "title" t,V.attr "aria-pressed" $ show $ D.valid saved,V.disabled $ D.s "url" t == "about:blank",V.click $ Browser (if D.valid saved then "unbookmark" else "bookmark") $ D.obj [Tuple "id" $ if D.valid saved then D.get "id" saved else D.get "id" t]] [V.text $ if D.valid saved then "★" else "☆"]
      ,V.node "button" [V.cls "tab-select",V.attr "aria-pressed" $ show active,V.attr "title" $ D.fallback (D.s "url" t) $ D.s "path" t,V.click $ Browser "focus" $ D.obj [Tuple "id" $ D.get "id" t]] [V.text $ D.fallback "New tab" $ D.s "title" t]
      ,V.node "button" [V.cls "tab-close",V.label $ "Close " <> D.s "title" t,V.click $ Browser "close" $ D.obj [Tuple "id" $ D.get "id" t]] [V.text "×"]]
  bookmarkRow b = let open = A.find (( _ == D.s "url" b) <<< D.s "url") tabs in V.div "bookmark-row"
    [V.button "" ("★ " <> D.s "title" b) $ case open of
      Just t -> Browser "focus" $ D.obj [Tuple "id" $ D.get "id" t]
      Nothing -> Browser "open" $ D.obj [Tuple "url" $ D.get "url" b]
    ,V.icon ("Remove " <> D.s "title" b <> " bookmark") "×" $ Browser "unbookmark" $ D.obj [Tuple "id" $ D.get "id" b]]

sync :: M.Model -> Effect Unit
sync m = when (D.b "native" m.env) do
  rect <- B.measure "#workspace-content"
  background <- B.cssProperty ".workspace" "--sapi-white"
  foreground <- B.cssProperty ".workspace" "--sapi-ink"
  caption <- B.cssProperty ".workspace" "--sapi-bg"
  B.nativeMessage $ D.obj [Tuple "workspaces" (if native m then m.workspaces else D.empty),Tuple "owner" (D.text $ if native m then m.selected else ""),Tuple "active" (D.get "id" $ M.activeTab m),Tuple "visible" (D.bool $ native m && A.elem N.Workspace (N.visiblePanes (N.limit m.env) (D.valid $ M.activeTab m) m.panes) && m.dialog == Nothing && m.menu == Nothing),Tuple "dark" (D.bool $ m.theme == "dark"),Tuple "background" (D.text background),Tuple "foreground" (D.text foreground),Tuple "captionBackground" (D.text caption),Tuple "rect" rect]

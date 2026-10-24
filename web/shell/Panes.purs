module Sapiens.Panes (main) where

import Prelude
import Data.Array as Array
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..), isJust)
import Data.Nullable (Nullable, toMaybe)
import Data.Number as Number
import Data.String.CodeUnits (take)
import Effect (Effect)
import Effect.Ref as Ref
import Effect.Uncurried (EffectFn1, mkEffectFn1, runEffectFn1)
import Sapiens.Browser as B

foreign import metrics :: Effect
  { touch :: Boolean, width :: Number, height :: Number, orientation :: Nullable String
  , visual :: Nullable {scale :: Number, height :: Number} }
foreign import onOrientation :: Effect Unit -> Effect Unit
foreign import onViewport :: Effect Unit -> Effect Unit
foreign import layout :: B.Element -> Effect { visible :: Boolean, scrollHeight :: Number }

data Pane = Sidebar | Chat | Workspace

derive instance eqPane :: Eq Pane

type Visibility = {sidebar :: Boolean, chat :: Boolean, workspace :: Boolean}
type Context =
  { syncWorkspace :: Effect Unit
  , activeTab :: Effect (Nullable String)
  , getPanes :: Effect Visibility
  , setPanes :: EffectFn1 Visibility Unit
  , selectedName :: Effect String
  }

name :: Pane -> String
name Sidebar = "sidebar"
name Chat = "chat"
name Workspace = "workspace"

get :: Pane -> Visibility -> Boolean
get Sidebar = _.sidebar
get Chat = _.chat
get Workspace = _.workspace

set :: Pane -> Boolean -> Visibility -> Visibility
set Sidebar value panes = panes {sidebar = value}
set Chat value panes = panes {chat = value}
set Workspace value panes = panes {workspace = value}

paneLimit :: Effect Int
paneLimit = do
  view <- metrics
  if not view.touch && view.width > 600.0 then pure 3
  else do
    let portrait = case toMaybe view.orientation of
          Just orientation | view.touch && orientation /= "" -> take 8 orientation == "portrait"
          _ -> view.height >= view.width
    pure $ if portrait then 1 else 2

syncMobileViewport :: Effect Unit
syncMobileViewport = do
  view <- metrics
  for_ (toMaybe view.visual) \viewport ->
    when (Number.abs (viewport.scale - 1.0) < 0.01) $
      B.setStyle "--mobile-viewport-height" (show viewport.height <> "px") B.root

resizeComposer :: Effect Unit
resizeComposer = do
  input <- B.query "#message-input" B.document
  for_ (toMaybe input) \element -> do
    limit <- paneLimit
    if limit == 3 then B.setStyle "height" "" element
    else do
      before <- layout element
      when before.visible do
        B.setStyle "height" "44px" element
        after <- layout element
        B.setStyle "height" (show (Int.floor $ min 140.0 $ max 44.0 after.scrollHeight) <> "px") element

mount :: Context -> Effect
  { showPane :: EffectFn1 String Unit, paneLimit :: Effect Int
  , renderPanes :: Effect Unit, resizeComposer :: Effect Unit, syncMobileViewport :: Effect Unit }
mount context = do
  order <- Ref.new [Chat, Sidebar, Workspace]
  let
    showPane value = for_ (Array.find (\pane -> name pane == value) [Sidebar, Chat, Workspace]) \pane -> do
      panes <- context.getPanes
      runEffectFn1 context.setPanes $ set pane true panes
      Ref.modify_ (\previous -> [pane] <> Array.filter (_ /= pane) previous) order
    renderPanes = do
      context.syncWorkspace
      saved <- context.getPanes
      active <- context.activeTab
      let requested = saved {workspace = saved.workspace && isJust (toMaybe active) && toMaybe active /= Just ""}
      limit <- paneLimit
      priority <- Ref.read order
      panes <- if limit < 3 then do
        let
          selected = Array.take limit $ Array.filter (\pane -> get pane requested) priority
          visible = if Array.null selected then [Chat] else selected
          reduced = {sidebar:Array.elem Sidebar visible, chat:Array.elem Chat visible, workspace:Array.elem Workspace visible}
        runEffectFn1 context.setPanes reduced
        pure reduced
        else pure requested
      B.setAttribute "data-pane-limit" (show limit) B.body
      if limit < 3 then B.setAttribute "data-mobile-ui" "" B.body else B.removeAttribute "data-mobile-ui" B.body
      syncMobileViewport
      input <- B.query "#message-input" B.document
      for_ (toMaybe input) \element -> do
        placeholder <- B.property "placeholder" element
        when (take 7 placeholder == "Message") do
          selected <- context.selectedName
          B.setProperty "placeholder" (if limit < 3 then "Message…" else "Message " <> selected <> "…") element
      for_ [Sidebar, Chat, Workspace] \pane -> do
        let
          visible = get pane panes
          id = case pane of
            Sidebar -> "#chat-list-panel"
            Chat -> "#chat-panel"
            Workspace -> "#workspace-panel"
          label = (if limit == 1 || not visible then "Show " else "Hide ") <>
            (if pane == Sidebar then "chat list" else name pane)
        panel <- B.query id B.document
        for_ (toMaybe panel) $ B.setProperty "hidden" (not visible)
        button <- B.query ("[data-toggle-pane=\"" <> name pane <> "\"]") B.document
        for_ (toMaybe button) \element -> do
          B.setAttribute "aria-pressed" (show visible) element
          B.setAttribute "aria-expanded" (show visible) element
          B.setAttribute "aria-label" label element
          B.setAttribute "title" label element
      let count = Array.length $ Array.filter identity [panes.sidebar, panes.chat, panes.workspace]
      grid <- B.query ".main-grid" B.document
      for_ (toMaybe grid) \element -> do
        B.setAttribute "data-visible-panes" (show count) element
        B.setStyle "grid-template-columns"
          ((if panes.sidebar then (if count == 1 then "minmax(0,1fr)" else "clamp(205px,18vw,250px)") else "0px") <> " " <>
           (if panes.chat then "minmax(300px,1fr)" else "0px") <> " " <>
           (if panes.workspace then "minmax(350px,1.2fr)" else "0px")) element
      resizeComposer
  B.listen "resize" false (const renderPanes) B.window
  onOrientation renderPanes
  onViewport syncMobileViewport
  input <- B.query "#message-input" B.document
  for_ (toMaybe input) $ B.listen "input" false (const resizeComposer)
  pure {showPane:mkEffectFn1 showPane, paneLimit, renderPanes, resizeComposer, syncMobileViewport}

main :: Effect Unit
main = B.expose "SapiensPanes" {mount:mkEffectFn1 mount}

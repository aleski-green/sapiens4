module Sapiens.RemoteInstall (main) where

import Prelude
import Control.Parallel (parOneOf)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Data.String (Pattern(..), contains)
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay, effectCanceler, launchAff_, makeAff, try)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Ref as Ref
import Sapiens.Async (Promise, fromPromise)
import Sapiens.Browser as B
import Sapiens.Runtime as Runtime
import Unsafe.Coerce (unsafeCoerce)

foreign import data Registration :: Type
foreign import data Worker :: Type
foreign import environment :: Effect { userAgent :: String, platform :: String, maxTouchPoints :: Int }
foreign import installed :: Effect Boolean
foreign import registration :: Effect (Promise (Nullable Registration))
foreign import update :: Registration -> Effect (Promise Unit)
foreign import workers :: Registration -> Effect { installing :: Nullable Worker, waiting :: Nullable Worker, active :: Nullable Worker }
foreign import workerState :: Worker -> Effect String
foreign import onWorkerState :: Worker -> Effect Unit -> Effect (Effect Unit)
foreign import prompt :: B.Event -> Effect (Promise Unit)
foreign import saveWorkspace :: Effect Unit
foreign import reload :: Effect Unit

await :: forall a. Effect (Promise a) -> Aff a
await operation = liftEffect operation >>= fromPromise

waitForWorker :: Worker -> Aff Unit
waitForWorker worker = makeAff \complete -> do
  disposed <- Ref.new false
  remove <- Ref.new (pure unit)
  let
    cleanup = do
      Ref.write true disposed
      action <- Ref.read remove
      action
    changed = do
      done <- Ref.read disposed
      unless done do
        state <- workerState worker
        when (state == "activated" || state == "redundant") do
          cleanup
          complete $ if state == "activated" then Right unit else Left $ error "Update unavailable"
  unsubscribe <- onWorkerState worker changed
  Ref.write unsubscribe remove
  changed
  pure $ effectCanceler cleanup

updateShell :: Aff Unit
updateShell = do
  reg <- await registration
  for_ (toMaybe reg) \value -> do
    await $ update value
    available <- liftEffect $ workers value
    let worker = case toMaybe available.installing of
          Just active -> Just active
          Nothing -> case toMaybe available.waiting of
            Just waiting -> Just waiting
            Nothing -> toMaybe available.active
    for_ worker waitForWorker

instructions :: Boolean -> String
instructions ios =
  "<div class=\"install-card\"><span class=\"install-brand\">Sapiens4</span>" <>
  "<h1>Add to Home Screen</h1><p>Install to connect your corpora.</p><ol>" <>
  (if ios then
    "<li>In Safari, tap <strong>Share</strong> <svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M12 15V3m-4 4 4-4 4 4M7 10H5v11h14V10h-2\"/></svg></li><li><strong>Add to Home Screen</strong><small>Open as Web App on → Add</small></li>"
   else "<li>In Chrome, tap <strong>⋮</strong></li><li><strong>Install and create shortcut</strong><small>Then tap Install</small></li>") <>
  "<li>Open <strong>Sapiens4</strong> from Home Screen.</li></ol>" <>
  "<button id=\"install-app\" type=\"button\" hidden>Install Sapiens4</button>" <>
  "<a href=\"https://sapiens4.ai/help?q=add2homescreen\" target=\"_blank\" rel=\"noopener noreferrer\">Need help? ↗</a></div>"

main :: Effect Unit
main = do
  info <- environment
  let
    ios = contains (Pattern "iPad") info.userAgent || contains (Pattern "iPhone") info.userAgent ||
      contains (Pattern "iPod") info.userAgent || (info.platform == "MacIntel" && info.maxTouchPoints > 1)
    mobile = ios || contains (Pattern "Android") info.userAgent
    reloadLogo = do
      app <- installed
      remote <- B.hasAttribute "data-remote" B.body
      pure $ ios && app && remote
  installPrompt <- Ref.new Nothing
  reloading <- Ref.new false
  let
    mount = do
      gate <- B.query "#mobile-install-gate" B.document
      for_ (toMaybe gate) \element -> do
        app <- installed
        let hidden = not mobile || app
        B.setProperty "hidden" hidden element
        unless hidden do
          Runtime.html (unsafeCoerce element) (instructions ios)
          button <- B.query "#install-app" B.document
          for_ (toMaybe button) \control -> do
            offered <- Ref.read installPrompt
            B.setProperty "hidden" (ios || case offered of
              Nothing -> true
              Just _ -> false) control
            B.listen "click" false (\_ -> do
              event <- Ref.read installPrompt
              Ref.write Nothing installPrompt
              B.setProperty "hidden" true control
              for_ event \invitation -> launchAff_ $ void $ try $ await $ prompt invitation
              ) control
  useReload <- reloadLogo
  when useReload do
    logo <- B.query ".wordmark" B.document
    for_ (toMaybe logo) \element -> do
      B.setAttribute "aria-label" "Reload Sapiens4 and check for updates" element
      B.setAttribute "title" "Reload and check for updates" element
  B.listen "click" true (\event -> do
    target <- B.target event
    logo <- B.closest ".wordmark" target
    enabled <- reloadLogo
    when enabled $ for_ (toMaybe logo) \element -> do
      B.preventDefault event
      B.stopImmediatePropagation event
      busy <- Ref.read reloading
      unless busy do
        Ref.write true reloading
        B.setAttribute "aria-busy" "true" element
        launchAff_ do
          -- A failed/offline update still reloads the last complete cached shell.
          void $ try do
            liftEffect saveWorkspace
            void $ parOneOf [try updateShell, delay (Milliseconds 12000.0) $> Left (error "Update timed out")]
          liftEffect saveWorkspace
          liftEffect reload
    ) B.document
  B.listen "beforeinstallprompt" false (\event -> do
    B.preventDefault event
    Ref.write (Just event) installPrompt
    mount
    ) B.window
  B.expose "RemoteInstall" {mount, installed, mobile}

module Sapiens.ConnectionsApp (main) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Aff (launchAff_, try)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Sapiens.Corpora as C
import Sapiens.Pairing as Pairing
import Sapiens.Runtime

main :: Effect Unit
main = do
  C.initialize
  Pairing.main
  s <- C.state
  menu <- q "#corpora-menu"
  statusMenu <- q "#corpora-status-menu"
  dialog <- q "#corpora-dialog"
  let closeMenus = setField menu "hidden" true *> setField statusMenu "hidden" true *> C.renderRows
  q "#corpora-dialog-close" >>= \node -> on node "click" false $ const C.closeForm
  on dialog "cancel" false \event -> prevent event *> C.closeForm
  on (global .! "window") "popstate" false \_ ->
    if boolean (s .! "suppressDialogPop") then setField s "suppressDialogPop" false
    else do
      when (boolean (dialog .! "open") && not (boolean $ global .! "history" .! "state" .! "sapiensDialog")) do
        C.cleanup
        void $ call dialog "close" []
      closeMenus
  q "#corpora-notice-close" >>= \node -> on node "click" false \_ -> q "#corpora-notice" >>= \notice -> void $ call notice "close" []
  q "#corpora-picker" >>= \node -> on node "click" false \_ -> do
    setField menu "hidden" $ not $ boolean $ menu .! "hidden"
    setField statusMenu "hidden" true
    C.renderRows
    unless (boolean $ menu .! "hidden") C.refreshPairings
  q "#connection-status" >>= \node -> on node "click" false \_ -> do
    setField statusMenu "hidden" $ not $ boolean $ statusMenu .! "hidden"
    setField menu "hidden" true
    C.renderRows
  q "#corpora-menu-close" >>= \node -> on node "click" false $ const closeMenus
  on (global .! "document") "click" false \event -> do
    path <- call event "composedPath" []
    unless (A.any (\node -> A.elem (field "id" node) ["corpora-picker","corpora-menu","connection-status","corpora-status-menu","corpora-dialog","corpora-notice"]) $ array path) closeMenus
  on (global .! "document") "keydown" false \event -> when (field "key" event == "Escape") closeMenus
  q "#corpora-archived" >>= \node -> on node "change" false $ const C.renderRows
  q "#corpora-rows" >>= \node -> on node "click" false \event -> do
    button <- closest (event .! "target") "button"
    let dataset = button .! "dataset"
    for_ ["enter","edit","pairing"] \command -> when (boolean $ dataset .! command) do
      let record = find (\r -> same (r .! "key") (dataset .! command)) $ items "records" s
      if command == "enter" then launchAff_ $ C.enter record
      else fire (if command == "edit" then "corporaEdit" else "remoteControl") [record]
  on statusMenu "click" false \event -> do
    button <- closest (event .! "target") "[data-lifecycle]"
    let action = field "lifecycle" $ button .! "dataset"
    when (action /= "" && not (boolean $ s .! "busy")) do
      setField s "busy" true
      C.renderStatus
      launchAff_ do
        result <- try $ C.reconcile *> C.lifecycle (s .! "active") action
        liftEffect do
          case result of
            Left error -> C.notice $ message error
            Right _ -> pure unit
          setField s "busy" false
          setField statusMenu "hidden" true
          C.renderStatus
  when (boolean (s .! "remote") && field "hash" (global .! "location") /= "") $ void $ call (global .! "history") "replaceState" [null,value "",global .! "location" .! "pathname"]
  when (boolean $ global .! "window" .! "matchMedia") do
    media <- call (global .! "window") "matchMedia" [value "(display-mode: standalone)"]
    on media "change" false \_ -> do
      installed <- call (global .! "window" .! "RemoteInstall") "installed" []
      when (boolean (s .! "installRequired") && boolean installed) C.start
  on (global .! "window") "online" false \_ -> unless (boolean (s .! "started") || boolean (s .! "installRequired")) C.restore
  C.start

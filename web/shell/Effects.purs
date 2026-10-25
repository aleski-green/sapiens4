module Sapiens.Effects where

import Prelude
import Control.Promise (toAffE)
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff, Milliseconds(..), delay, try, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (Error, error, message)
import Foreign.Object as O
import Halogen as H
import Libs4.Browser as B
import Sapiens.Action (Action(..))
import Sapiens.Connections as C
import Sapiens.Data as D
import Sapiens.Memo as Memo
import Sapiens.Model as M
import Sapiens.Navigation as N
import Sapiens.Remote as R
import Sapiens.Workspace as W

type UI = H.HalogenM M.Model Action () Void Aff
type Dispatch = Action -> UI Unit

later :: Dispatch -> Number -> Action -> UI Unit
later dispatch ms action = void $ H.fork $ H.liftAff (delay $ Milliseconds ms) *> dispatch action

run :: forall a. (Either Error a -> Action) -> Aff a -> Dispatch -> UI Unit
run respond operation dispatch = void $ H.fork $ H.liftAff (try operation) >>= dispatch <<< respond

api :: C.Runtime -> M.Model -> String -> String -> Json -> Aff Json
api runtime m path method body = do
  when (m.busy || m.active == "") $ throwError $ error "Connecting…"
  when (not m.online && method /= "GET") $ throwError $ error "Offline — read only."
  C.request runtime (M.remote m) (M.activeRecord m) path method body

notify :: Dispatch -> String -> UI Unit
notify dispatch text = do
  H.modify_ _ { toast=text }
  later dispatch 3200.0 (ClearToast text)

persistLocal :: UI Unit
persistLocal = do
  m <- H.get
  when (m.active /= "") do
    ok <- liftEffect $ C.write ("s4.workspace." <> m.active) $ M.preferences m
    unless ok $ H.modify_ _ { feedback="Device storage is unavailable. Keep this window open to retain your draft." }

save :: Dispatch -> UI Unit
save dispatch = persistLocal *> later dispatch 300.0 Persist

requestDocument :: C.Runtime -> Dispatch -> UI Unit
requestDocument runtime dispatch = do
  m <- H.get
  case M.currentDocument m of
    Nothing -> pure unit
    Just request -> do
      let old = fromMaybe M.NotAsked $ O.lookup request.key m.documents
      unless ((_.revision <$> M.requestOf old) == Just request.revision) do
        H.modify_ _ { sequence=request.sequence, documents=O.insert request.key (M.Loading request $ M.valueOf old) m.documents }
        run (DocumentReceived request) (api runtime m request.path "GET" D.null) dispatch

memoImages :: C.Runtime -> Dispatch -> Json -> UI Unit
memoImages runtime dispatch document = do
  m <- H.get
  traverse_ (\source -> do
    let key = m.selected <> ":" <> source
    unless (D.valid $ D.get key m.imageUrls) $ run (MemoImageReceived m.epoch key) (imageRequest m source) dispatch) $ Memo.imagePaths document
  where
  imageRequest m source = do
    let path = M.ownerPath m <> "/notes?image=" <> B.encodeURI source
    result <- if M.remote m then do
      client <- C.client runtime (M.activeRecord m)
      R.request client 15000 $ D.obj [Tuple "kind" (D.text "request"),Tuple "op" (D.text "api"),Tuple "method" (D.text "GET"),Tuple "path" (D.text path)]
      else toAffE $ B.requestBytes ("/api/host/corpora/" <> B.encodeURI (D.s "id" $ M.activeRecord m) <> path) (D.obj [Tuple "X-Sapiens-Local" $ D.text "1"])
    unless (D.n "status" result == 200.0 && D.matches "^image/(png|jpeg|gif|webp|svg\\+xml)(;|$)" (D.s "mime" result)) $ throwError $ error "Image unavailable"
    pure $ "data:" <> D.s "mime" result <> ";base64," <> D.s "body" result

preview :: C.Runtime -> Dispatch -> UI Unit
preview runtime dispatch = do
  m <- H.get
  let tab = M.activeTab m
      path = if D.s "path" tab == "" then "" else M.ownerPath m <> "/browser/" <> B.encodeURI (D.s "id" tab) <> "/content"
  unless (W.native m || path == "" || not (A.elem N.Workspace m.panes)) do
    let request = {epoch:m.epoch,sequence:m.sequence+1,key:D.s "id" tab,revision:D.encode $ D.get "command" tab,path}
        pending = case m.preview of
          M.Loading _ _ -> true
          _ -> false
    unless pending do
      H.modify_ _ { sequence=request.sequence,previewPath=path,preview=M.Loading request $ if path == m.previewPath then M.valueOf m.preview else Nothing }
      run (PreviewReceived request) (api runtime m path "GET" D.null) dispatch

captureScroll :: UI Unit
captureScroll = do
  m <- H.get
  when (m.activity == N.Chat N.Conversation && not (D.b "hidden" m.env) && not m.restoringScroll) do
    viewport <- liftEffect $ B.measure "#conversation-body"
    when (D.n "clientHeight" viewport > 0.0) do
      children <- liftEffect $ B.measureChildren "#conversation-body"
      let first = fromMaybe D.null $ A.find (\node -> D.str (D.at ["dataset","chatKey"] node) /= "" && D.n "bottom" node > D.n "top" viewport) children
          position = D.obj [Tuple "selected" (D.text m.selected),Tuple "bottom" (D.bool $ D.n "scrollHeight" viewport - D.n "scrollTop" viewport - D.n "clientHeight" viewport < 2.0),Tuple "key" (D.at ["dataset","chatKey"] first),Tuple "offset" (D.number $ D.n "top" first - D.n "top" viewport),Tuple "width" (D.get "clientWidth" viewport),Tuple "height" (D.get "clientHeight" viewport)]
      when (not (D.valid m.scrollPosition) || D.n "width" m.scrollPosition == D.n "clientWidth" viewport && D.n "height" m.scrollPosition == D.n "clientHeight" viewport) $ H.modify_ _ { scrollPosition=position }

restoreScroll :: UI Unit
restoreScroll = do
  m <- H.get
  when (m.activity == N.Chat N.Conversation && not (D.b "hidden" m.env)) do
    let saved = m.scrollPosition
    when (D.s "selected" saved == m.selected) do
      viewport <- liftEffect $ B.measure "#conversation-body"
      children <- liftEffect $ B.measureChildren "#conversation-body"
      let node = A.find (( _ == D.s "key" saved) <<< D.str <<< D.at ["dataset","chatKey"]) children
      when (D.n "clientHeight" viewport > 0.0 && (D.b "bottom" saved || node /= Nothing)) do
        let target = if D.b "bottom" saved then D.n "scrollHeight" viewport - D.n "clientHeight" viewport else D.n "scrollTop" viewport + D.n "top" (fromMaybe D.null node) - D.n "top" viewport - D.n "offset" saved
        liftEffect $ B.scroll "#conversation-body" target
        H.modify_ _ { restoringScroll=false }

scrollBottom :: UI Unit
scrollBottom = do
  m <- H.get
  H.modify_ _ { scrollPosition=D.obj [Tuple "selected" (D.text m.selected),Tuple "bottom" (D.bool true)],restoringScroll=true }
  restoreScroll

sync :: UI Unit
sync = do
  m <- H.get
  liftEffect do
    B.setAttribute "html" "data-theme" m.theme
    B.setStyle "html" "color-scheme" m.theme
    B.setAttribute "link[rel=icon]" "href" $ if m.theme == "dark" then "/favicon-dark.svg" else "/favicon.svg"
    B.setAttribute "body" "data-pane-limit" $ show $ N.limit m.env
    if N.limit m.env < 3 then B.setAttribute "body" "data-mobile-ui" "" else B.removeAttribute "body" "data-mobile-ui"
    when (D.n "viewportScale" m.env == 1.0) $ B.setStyle "html" "--mobile-viewport-height" (show (D.n "viewportHeight" m.env) <> "px")
    B.showDialog (if maybeCorpora m then "#corpora-dialog" else "#modal") $ m.dialog /= Nothing
    W.sync m
  resizeComposer
  where
  maybeCorpora m = case m.dialog of
    Nothing -> false
    Just d -> A.elem d.kind [M.CreateCorpora,M.EditCorpora,M.ConnectRemote,M.HostPairing,M.RelayList,M.RelayAdd,M.RelaySwitch,M.RelayTerms,M.Notice]

resizeComposer :: UI Unit
resizeComposer = do
  m <- H.get
  if N.limit m.env == 3 then liftEffect $ B.setStyle "#message-input" "height" "" else do
    liftEffect $ B.setStyle "#message-input" "height" "44px"
    box <- liftEffect $ B.measure "#message-input"
    when (D.n "height" box > 0.0) $ liftEffect $ B.setStyle "#message-input" "height" (show (min 140.0 $ max 44.0 $ D.n "scrollHeight" box) <> "px")

errorMessage :: forall a. Either Error a -> String
errorMessage = case _ of
  Left failure -> message failure
  Right _ -> ""

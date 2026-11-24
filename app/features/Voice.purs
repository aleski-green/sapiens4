module Sapiens.Voice where

import Prelude
import Control.Promise (toAffE)
import Data.Array as A
import Data.Either (Either(..), either)
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), maybe)
import Data.String as S
import Effect.Class (liftEffect)
import Effect.Exception (Error, message)
import Foreign.Object as O
import Halogen as H
import Halogen.Subscription as HS
import Sapiens.BrowserFFI as B
import Sapiens.Action (Action(..))
import Sapiens.Config as Config
import Sapiens.Connections as C
import Sapiens.Data as D
import Sapiens.Domain as X
import Sapiens.Effects as E
import Sapiens.Model as M

type Ctx = { runtime :: C.Runtime, dispatch :: E.Dispatch }

type Outgoing = { owner :: String, voiceId :: String, outbox :: M.Outbox }

handle :: C.Runtime -> E.Dispatch -> Action -> E.UI Boolean
handle runtime dispatch action = case action of
  VoiceStart -> startRecording $> true
  VoiceProgress ms -> showProgress ms $> true
  VoiceStop -> stopWith M.Review $> true
  VoiceStopSend -> stopWith M.SendAfter $> true
  VoiceCancel -> cancelRecording ctx $> true
  VoiceSend -> queueSend ctx $> true
  VoiceResume -> resumePendingVoice ctx $> true
  VoicePiece piece -> acceptPiece ctx piece $> true
  VoicePieceRejected reason -> rejectPiece ctx reason $> true
  VoiceRetry id -> retryTranscript ctx id $> true
  _ -> pure false
  where
  ctx = { runtime, dispatch }

startRecording :: E.UI Unit
startRecording = do
  m <- H.get
  case m.voice, M.selectedChat m of
    Just v, _ | v.owner /= m.selected -> E.notify "Finish or cancel the voice recording in the other chat first."
    Just _, _ -> pure unit
    Nothing, _ | M.ordinaryAttachmentCount m >= Config.maxAttachments -> E.notify "Remove an attachment to make room for a voice message."
    Nothing, Just owner -> openRecording m owner
    Nothing, Nothing -> pure unit

openRecording :: M.Model -> String -> E.UI Unit
openRecording m owner = do
  { emitter, listener } <- liftEffect HS.create
  subscription <- H.subscribe emitter
  H.modify_ _ { voice = Just (newSession m owner subscription) }
  let onPiece = HS.notify listener <<< either VoicePieceRejected VoicePiece <<< X.voicePiece
      onSecond = HS.notify listener <<< VoiceProgress
      recorder = B.voiceStart "/voice-worklet.js" Config.voicePieceSeconds onPiece onSecond
  E.attempt (toAffE recorder) (microphoneReady subscription)

newSession :: M.Model -> String -> H.SubscriptionId -> M.VoiceSession
newSession m owner subscription =
  { owner, path: M.ownerPath m <> "/voice", epoch: m.epoch, phase: M.Starting, subscription
  , queue: [], sending: false, attempts: 0, pieces: 0, recording: Nothing, elapsed: 0.0 }

microphoneReady :: H.SubscriptionId -> Either Error B.Voice -> E.UI Unit
microphoneReady subscription result = H.gets _.voice >>= case _ of
  Just w | w.subscription == subscription -> case result, w.phase of
    Right recorder, M.Starting -> H.modify_ _ { voice = Just w { phase = M.Recording recorder } }
    Right recorder, _ -> stopRecorder recorder
    Left err, _ -> do
      H.unsubscribe subscription
      H.modify_ _ { voice = Nothing }
      E.notify ("Microphone unavailable: " <> message err)
  _ -> case result of
    Right recorder -> stopRecorder recorder
    Left _ -> H.unsubscribe subscription

showProgress :: Number -> E.UI Unit
showProgress ms = do
  m <- H.get
  case m.voice of
    Just v | v.epoch /= m.epoch -> abandonRecording v
    Just _ -> H.modify_ \s -> s { voice = map (_ { elapsed = ms }) s.voice }
    Nothing -> pure unit

stopRecorder :: B.Voice -> E.UI Unit
stopRecorder recorder = E.attempt (toAffE $ B.voiceStop recorder) (const (pure unit))

stopWith :: M.StopAction -> E.UI Unit
stopWith after = H.gets _.voice >>= traverse_ \v -> unless (M.isStopping v.phase) do
  H.modify_ _ { voice = Just v { phase = M.Stopping after } }
  traverse_ stopRecorder (M.phaseRecorder v.phase)

cancelRecording :: Ctx -> E.UI Unit
cancelRecording ctx = H.gets _.voice >>= traverse_ \v -> do
  abandonRecording v
  E.inEpoch v.epoch \_ -> do
    H.modify_ \m -> m { attachments = O.update (Just <<< A.filter (not <<< fromRecording v.recording)) v.owner m.attachments }
    E.save ctx.dispatch
    cancelOnHost ctx v

fromRecording :: Maybe String -> X.Attachment -> Boolean
fromRecording recording item = case recording, X.voiceOf item of
  Just id, Just note -> note.recording == id
  _, _ -> false

cancelOnHost :: Ctx -> M.VoiceSession -> E.UI Unit
cancelOnHost ctx v = flip traverse_ v.recording \id -> E.inEpoch v.epoch \m -> do
  let path = v.path <> "/" <> id <> "/cancel"
  E.attempt (E.api ctx.runtime m path "POST" (D.json {})) \result -> E.inEpoch v.epoch \_ -> case result of
    Left err -> E.notify ("The cancelled recording could not be removed from the computer: " <> message err)
    Right _ -> ctx.dispatch Poll

queueSend :: Ctx -> E.UI Unit
queueSend ctx = do
  m <- H.get
  let owner = m.selected
      recordingHere = maybe false (\v -> v.owner == owner) m.voice
  when (not (O.member owner m.outboxes) && not recordingHere && M.online m) do
    H.modify_ \s -> s { outboxes = O.insert owner (newOutbox m) s.outboxes }
    flushOutbox ctx owner

newOutbox :: M.Model -> M.Outbox
newOutbox m =
  let items = M.attachments m
  in { epoch: m.epoch, path: M.ownerPath m <> "/messages", text: S.trim (M.draft m)
     , others: map _.id (A.filter (not <<< X.isVoice) items), voices: map _.id (A.filter X.isVoice items), sending: false }

flushOutbox :: Ctx -> String -> E.UI Unit
flushOutbox ctx owner = H.get >>= \m -> traverse_ (flushOutboxWith ctx m owner) (O.lookup owner m.outboxes)

flushOutboxWith :: Ctx -> M.Model -> String -> M.Outbox -> E.UI Unit
flushOutboxWith ctx m owner o
  | o.epoch /= m.epoch = H.modify_ \s -> s { outboxes = O.delete owner s.outboxes }
  | o.sending = pure unit
  | otherwise = case A.head o.voices of
      Nothing -> do
        H.modify_ \s -> s { outboxes = O.delete owner s.outboxes }
        ctx.dispatch Poll
      Just voiceId -> case O.lookup owner m.attachments >>= A.find ((_ == voiceId) <<< _.id) of
        Nothing -> do
          H.modify_ \s -> s { outboxes = O.update (\x -> Just x { voices = A.drop 1 x.voices }) owner s.outboxes }
          flushOutbox ctx owner
        Just item -> sendWhenTranscribed ctx m { owner, voiceId, outbox: o } item

sendWhenTranscribed :: Ctx -> M.Model -> Outgoing -> X.Attachment -> E.UI Unit
sendWhenTranscribed ctx m out item = case map _.transcription (X.voiceOf item) of
  Just (X.Transcribed _) -> sendVoice ctx m out
  Just (X.TranscriptFailed _) -> do
    H.modify_ \s -> s { outboxes = O.delete out.owner s.outboxes }
    E.notify (item.name <> " couldn't be transcribed. Retry it or remove it, then press Send again.")
  _ -> pure unit

sendVoice :: Ctx -> M.Model -> Outgoing -> E.UI Unit
sendVoice ctx m out = do
  let o = out.outbox
      body = D.json { text: o.text, attachments: o.others <> [out.voiceId] }
  H.modify_ \s -> s { outboxes = O.update (\x -> Just x { sending = true }) out.owner s.outboxes }
  E.attempt (E.api ctx.runtime m o.path "POST" body) \result -> do
    s <- H.get
    when (s.epoch == o.epoch) case result of
      Left err -> do
        H.modify_ \x -> x { outboxes = O.delete out.owner x.outboxes }
        E.notify ("Voice message could not be sent: " <> message err <> ". Press Send to continue.")
      Right _ -> voiceSent ctx out

voiceSent :: Ctx -> Outgoing -> E.UI Unit
voiceSent ctx out = do
  let o = out.outbox
      sent item = item.id == out.voiceId || A.elem item.id o.others
      advance b = b { text = "", others = [], voices = A.drop 1 b.voices, sending = false }
  H.modify_ \x -> x { outboxes = O.update (Just <<< advance) out.owner x.outboxes
                    , attachments = O.update (Just <<< A.filter (not <<< sent)) out.owner x.attachments
                    , drafts = O.update (Just <<< clearSentDraft o) out.owner x.drafts }
  E.save ctx.dispatch
  ctx.dispatch Poll
  flushOutbox ctx out.owner

clearSentDraft :: M.Outbox -> String -> String
clearSentDraft sent draft = if not (S.null sent.text) && S.trim draft == sent.text then "" else draft

acceptPiece :: Ctx -> X.VoicePiece -> E.UI Unit
acceptPiece ctx piece = H.gets _.voice >>= traverse_ \v ->
  when (maybe true (_ == piece.recording) v.recording) $
    if A.length v.queue >= Config.voiceMaxBacklog then do
      abandonRecording v
      E.notify "Recording stopped: the connection is too slow to upload the voice in time. Finished voice messages stay in the composer."
    else do
      H.modify_ \m -> m { voice = map (\w -> w { queue = A.snoc w.queue piece, recording = Just piece.recording }) m.voice }
      drainUploads ctx

rejectPiece :: Ctx -> String -> E.UI Unit
rejectPiece ctx reason = H.gets _.voice >>= traverse_ \v -> do
  abandonRecording v
  cancelOnHost ctx v
  E.notify ("Voice recording stopped: the recorder sent a damaged piece (" <> reason <> ").")

retryTranscript :: Ctx -> String -> E.UI Unit
retryTranscript ctx id = do
  m <- H.get
  let owner = m.selected
      path = M.ownerPath m <> "/attachments/" <> id <> "/transcribe"
  E.attempt (E.api ctx.runtime m path "POST" (D.json {})) \result -> E.inEpoch m.epoch \_ -> case result of
    Left err -> E.notify ("Could not retry the transcription: " <> message err)
    Right reply -> do
      let row = X.attachment reply
      H.modify_ \s -> s { attachments = O.update (Just <<< map (\item -> if item.id == row.id then row else item)) owner s.attachments }

resumePendingVoice :: Ctx -> E.UI Unit
resumePendingVoice ctx = do
  drainUploads ctx
  H.gets (O.keys <<< _.outboxes) >>= traverse_ (flushOutbox ctx)

drainUploads :: Ctx -> E.UI Unit
drainUploads ctx = H.get >>= \m -> traverse_ (drainSession ctx m) m.voice

drainSession :: Ctx -> M.Model -> M.VoiceSession -> E.UI Unit
drainSession ctx m v
  | m.epoch /= v.epoch = abandonRecording v
  | v.sending = pure unit
  | otherwise = traverse_ (uploadPiece ctx m v) (A.head v.queue)

uploadPiece :: Ctx -> M.Model -> M.VoiceSession -> X.VoicePiece -> E.UI Unit
uploadPiece ctx m v piece = do
  H.modify_ _ { voice = Just v { sending = true } }
  E.attempt (E.api ctx.runtime m v.path "POST" piece.wire) \result -> H.get >>= \current -> case current.voice of
    Just w | w.subscription == v.subscription && w.epoch /= current.epoch -> abandonRecording w
    Just w | w.subscription == v.subscription -> uploaded ctx w piece (map (map X.attachment <<< D.rows "messages") result)
    _ -> pure unit

uploaded :: Ctx -> M.VoiceSession -> X.VoicePiece -> Either Error (Array X.Attachment) -> E.UI Unit
uploaded ctx w piece = case _ of
  Right rows -> do
    addCuts ctx w rows
    if piece.final then finishRecording ctx w else do
      H.modify_ \s -> s { voice = map (\x -> x { queue = A.drop 1 x.queue, sending = false, attempts = 0, pieces = x.pieces + 1 }) s.voice }
      drainUploads ctx
  Left err
    | w.attempts + 1 >= Config.voiceMaxAttempts -> do
        abandonRecording w
        E.notify ("Voice message could not be sent: " <> message err)
    | otherwise -> do
        H.modify_ \s -> s { voice = map (\x -> x { sending = false, attempts = x.attempts + 1 }) s.voice }

addCuts :: Ctx -> M.VoiceSession -> Array X.Attachment -> E.UI Unit
addCuts ctx v rows = unless (A.null rows) do
  H.modify_ \m -> m { attachments = O.alter (Just <<< withCuts rows) v.owner m.attachments }
  E.save ctx.dispatch

withCuts :: Array X.Attachment -> Maybe (Array X.Attachment) -> Array X.Attachment
withCuts rows = maybe rows \items -> items <> A.filter (\row -> not (A.any ((_ == row.id) <<< _.id) items)) rows

finishRecording :: Ctx -> M.VoiceSession -> E.UI Unit
finishRecording ctx v = do
  H.unsubscribe v.subscription
  H.modify_ _ { voice = Nothing }
  ctx.dispatch Poll
  m <- H.get
  case v.phase of
    M.Stopping M.SendAfter | m.selected == v.owner && A.any X.isVoice (M.attachments m) -> ctx.dispatch Send
    _ -> pure unit

abandonRecording :: M.VoiceSession -> E.UI Unit
abandonRecording v = do
  traverse_ stopRecorder (M.phaseRecorder v.phase)
  H.unsubscribe v.subscription
  H.modify_ _ { voice = Nothing }

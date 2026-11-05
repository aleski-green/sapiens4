module Sapiens.Voice where

import Prelude
import Control.Promise (toAffE)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.String as S
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Foreign.Object as O
import Halogen as H
import Halogen.Subscription as HS
import Libs4.Browser as B
import Sapiens.Action (Action(..))
import Sapiens.Connections as C
import Sapiens.Data as D
import Sapiens.Domain as X
import Sapiens.Effects as E
import Sapiens.Model as M

-- | Seconds of audio per streamed piece. The host joins pieces and cuts one-minute voice messages.
pieceSeconds :: Int
pieceSeconds = 2

-- | A piece that keeps failing to upload is retried this many times before the recording is dropped.
maxAttempts :: Int
maxAttempts = 5

-- | Recording, ordered upload, the live timer, stopping, cancelling and sending. Returns true when it handled the action.
-- | Finished one-minute voice messages come back from the host and wait in the composer. Stop keeps them
-- | there for review; Send (in the recording bar) stops and sends them as soon as recording finishes. On Send, each voice
-- | message becomes its own chat message, in order, as soon as its own transcript is ready: the first
-- | goes at once while later ones are still being transcribed.
handle :: C.Runtime -> E.Dispatch -> Action -> E.UI Boolean
handle runtime dispatch action = case action of
  VoiceStart -> do
    m <- H.get
    when (isNothing m.voice && m.selected /= "") do
      startedAt <- liftEffect B.now
      { emitter, listener } <- liftEffect HS.create
      subscription <- H.subscribe (VoicePiece <$> emitter)
      H.modify_ _ { voice = Just { owner: m.selected, path: M.ownerPath m <> "/voice", epoch: m.epoch, recorder: Nothing, subscription
                                 , queue: [], sending: false, attempts: 0, pieces: 0, stopping: false
                                 , recording: "", startedAt, elapsed: 0.0, thenSend: false } }
      E.later 1000.0 (dispatch VoiceTick)
      E.attempt (toAffE $ B.voiceStart "/voice-worklet.js" pieceSeconds (HS.notify listener)) case _ of
        Left err -> do
          H.unsubscribe subscription
          H.modify_ _ { voice = Nothing }
          E.notify ("Microphone unavailable: " <> message err)
        Right recorder -> H.gets _.voice >>= case _ of
          Just v | v.subscription == subscription -> do
            H.modify_ _ { voice = Just v { recorder = Just recorder } }
            when v.stopping $ stopRecorder recorder
          _ -> stopRecorder recorder
    pure true
  VoiceTick -> do
    H.gets _.voice >>= traverse_ \v -> unless v.stopping do
      now <- liftEffect B.now
      H.modify_ \m -> m { voice = map (_ { elapsed = now - v.startedAt }) m.voice }
      E.later 1000.0 (dispatch VoiceTick)
    pure true
  VoiceStop -> do
    H.gets _.voice >>= traverse_ \v -> do
      H.modify_ _ { voice = Just v { stopping = true } }
      traverse_ stopRecorder v.recorder
    pure true
  VoiceStopSend -> do
    H.gets _.voice >>= traverse_ \v -> do
      H.modify_ _ { voice = Just v { stopping = true, thenSend = true } }
      traverse_ stopRecorder v.recorder
    pure true
  VoiceCancel -> do
    H.gets _.voice >>= traverse_ \v -> do
      traverse_ stopRecorder v.recorder
      H.unsubscribe v.subscription
      H.modify_ \m -> m { voice = Nothing, attachments = O.update (Just <<< A.filter (\item -> v.recording == "" || item.recording /= v.recording)) v.owner m.attachments }
      E.save dispatch
    pure true
  VoiceSend -> do
    m <- H.get
    when (isNothing m.outbox && isNothing m.voice && M.online m) do
      let items = M.attachments m
          voices = map _.id $ A.filter ((_ == X.VoiceAttachment) <<< _.kind) items
          others = map _.id $ A.filter ((_ /= X.VoiceAttachment) <<< _.kind) items
      H.modify_ _ { outbox = Just { owner: m.selected, path: M.ownerPath m <> "/messages", text: S.trim (M.draft m), others, voices, sending: false } }
      flush
    pure true
  VoiceFlush -> do
    flush
    pure true
  VoicePiece piece -> do
    H.modify_ \m -> m { voice = map (\v -> v { queue = A.snoc v.queue piece, recording = D.s "recording" piece }) m.voice }
    drain
    pure true
  _ -> pure false
  where
  stopRecorder recorder = E.attempt (toAffE $ B.voiceStop recorder) (const (pure unit))
  drain = H.get >>= \m -> traverse_ (step m) m.voice
  step m v
    | m.epoch /= v.epoch = abandon v
    | v.sending = pure unit
    | otherwise = traverse_ (upload m v) (A.head v.queue)
  upload m v piece = do
    H.modify_ _ { voice = Just v { sending = true } }
    E.attempt (E.api runtime m v.path "POST" piece) \result -> H.gets _.voice >>= case _ of
      -- The same recording is still running: a reply from a cancelled or replaced recording is ignored.
      Just w | w.subscription == v.subscription -> case result of
        Right reply -> do
          addCuts w (D.rows "messages" reply)
          if D.b "final" piece then finish w else do
            H.modify_ \s -> s { voice = map (\x -> x { queue = A.drop 1 x.queue, sending = false, attempts = 0, pieces = x.pieces + 1 }) s.voice }
            drain
        Left err
          | w.attempts + 1 >= maxAttempts -> do
              abandon w
              E.notify ("Voice message could not be sent: " <> message err)
          | otherwise -> do
              H.modify_ \s -> s { voice = map (\x -> x { sending = false, attempts = x.attempts + 1 }) s.voice }
              E.later 1000.0 drain
      _ -> pure unit
  -- Each finished voice message joins the composer's attachments for review (no duplicates on a resend).
  addCuts v replies = unless (A.null replies) do
    let rows = map X.attachment replies
    H.modify_ \m -> m { attachments = O.alter (\current -> let items = fromMaybe [] current in Just (items <> A.filter (\row -> not (A.any ((_ == row.id) <<< _.id) items)) rows)) v.owner m.attachments }
    E.save dispatch
  -- Send the next voice message once its transcript is ready (or failed); keep waiting while Whisper works.
  -- The person's typed text and other attachments travel with the first voice message.
  flush = H.get >>= \m -> traverse_ (flushWith m) m.outbox
  flushWith m o = unless o.sending $ case A.head o.voices of
    Nothing -> do
      H.modify_ _ { outbox = Nothing }
      dispatch Poll
    Just voiceId -> case A.find ((_ == voiceId) <<< _.id) (fromMaybe [] $ O.lookup o.owner m.attachments) of
      Nothing -> do
        H.modify_ \s -> s { outbox = map (\x -> x { voices = A.drop 1 x.voices }) s.outbox }
        flush
      Just item
        | item.transcriptStatus == "pending" -> E.later 1500.0 (dispatch VoiceFlush)
        | otherwise -> sendVoice m o voiceId
  sendVoice m o voiceId = do
    H.modify_ \s -> s { outbox = map (_ { sending = true }) s.outbox }
    E.attempt (E.api runtime m o.path "POST" (D.json { text: o.text, attachments: o.others <> [voiceId] })) case _ of
      Left err -> do
        H.modify_ _ { outbox = Nothing }
        E.notify ("Voice message could not be sent: " <> message err <> ". Press Send to continue.")
      Right _ -> do
        H.modify_ \s -> s { outbox = map (\x -> x { text = "", others = [], voices = A.drop 1 x.voices, sending = false }) s.outbox
                          , attachments = O.update (Just <<< A.filter (\item -> item.id /= voiceId && not (A.elem item.id o.others))) o.owner s.attachments
                          , drafts = if o.text /= "" then O.insert o.owner "" s.drafts else s.drafts }
        E.save dispatch
        dispatch Poll
        flush
  -- Recording is complete. After Send-while-recording, send now, but only if the person is still in the
  -- chat they recorded in; otherwise the voice messages stay in that chat's composer for review.
  finish v = do
    H.unsubscribe v.subscription
    H.modify_ _ { voice = Nothing }
    dispatch Poll
    m <- H.get
    when (v.thenSend && m.selected == v.owner) $ dispatch VoiceSend
  abandon v = do
    traverse_ stopRecorder v.recorder
    H.unsubscribe v.subscription
    H.modify_ _ { voice = Nothing }

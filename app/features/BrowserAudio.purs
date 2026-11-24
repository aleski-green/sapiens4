module Sapiens.BrowserAudio where

import Prelude
import Control.Monad.Rec.Class (Step(..), tailRecM)
import Control.Promise (Promise, fromAff, toAffE)
import Data.Argonaut.Core (Json)
import Data.Foldable (traverse_)
import Data.Int as I
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Effect (Effect)
import Effect.Aff (attempt, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Effect.Ref as Ref
import Data.Either (Either(..))
import Sapiens.BrowserNative as N
import Sapiens.Config as Config
import Sapiens.Data as D

foreign import data Samples :: Type
foreign import data Wave :: Type
foreign import data Stream :: Type
foreign import data Context :: Type
foreign import data Connection :: Type
foreign import allocate :: Int -> Effect Samples
foreign import sampleCount :: Samples -> Int
foreign import sampleAt :: Samples -> Int -> Number
foreign import writeSample :: Samples -> Int -> Number -> Effect Unit
foreign import sliceSamples :: Int -> Int -> Samples -> Samples
foreign import appendSamples :: Samples -> Samples -> Samples
foreign import allocateWave :: Int -> Effect Wave
foreign import write8 :: Wave -> Int -> Int -> Effect Unit
foreign import write16 :: Wave -> Int -> Number -> Effect Unit
foreign import write32 :: Wave -> Int -> Int -> Effect Unit
foreign import waveBase64 :: Wave -> String
foreign import microphone :: Json -> Effect (Promise Stream)
foreign import newContext :: Effect Context
foreign import sampleRate :: Context -> Number
foreign import loadWorklet :: Context -> String -> Effect (Promise Unit)
foreign import connectAudio :: Context -> Stream -> String -> (Samples -> Effect Unit) -> Effect Connection
foreign import disconnectAudio :: Connection -> Effect Unit
foreign import stopTracks :: Stream -> Effect Unit
foreign import closeContext :: Context -> Effect (Promise Unit)
foreign import microphoneAvailable :: Effect Boolean

type Voice = { stop :: Effect (Promise Json) }
type Recording = {buffer :: Samples, filled :: Int, index :: Int, carry :: Samples, position :: Number}

wav :: Samples -> Effect String
wav samples = do
  let count = sampleCount samples
  view <- allocateWave $ 44 + count * 2
  traverse_ (\{offset, value} -> write8 view offset value)
    [{offset:0,value:82},{offset:1,value:73},{offset:2,value:70},{offset:3,value:70}
    ,{offset:8,value:87},{offset:9,value:65},{offset:10,value:86},{offset:11,value:69}
    ,{offset:12,value:102},{offset:13,value:109},{offset:14,value:116},{offset:15,value:32}
    ,{offset:36,value:100},{offset:37,value:97},{offset:38,value:116},{offset:39,value:97}]
  write32 view 4 $ 36 + count * 2
  write32 view 16 16
  write16 view 20 1.0
  write16 view 22 1.0
  write32 view 24 16000
  write32 view 28 32000
  write16 view 32 2.0
  write16 view 34 16.0
  write32 view 40 $ count * 2
  tailRecM (\index -> if index >= count then pure $ Done unit else do
    write16 view (44 + index * 2) $ max (-1.0) (min 1.0 $ sampleAt samples index) * 32767.0
    pure $ Loop $ index + 1) 0
  pure $ waveBase64 view

average :: Samples -> Int -> Int -> Number
average input start end = if end <= start then sampleAt input start else go start 0.0 / I.toNumber (end - start)
  where
  go index total | index >= end = total
                 | otherwise = go (index + 1) (total + sampleAt input index)

voiceStart :: String -> Int -> (Json -> Effect Unit) -> (Number -> Effect Unit) -> Effect (Promise Voice)
voiceStart workletUrl segmentSeconds onSegment onSecond = fromAff do
  available <- liftEffect microphoneAvailable
  unless available $ throwError $ error "Microphone is not available here."
  when (segmentSeconds <= 0) $ throwError $ error "Segment length must be positive."
  stream <- toAffE $ microphone $ D.json {audio: {channelCount: 1, echoCancellation: true, noiseSuppression: true}, video: false}
  created <- attempt $ liftEffect newContext
  context <- case created of
    Right value -> pure value
    Left failure -> do
      liftEffect $ stopTracks stream
      throwError failure
  result <- attempt do
    toAffE $ loadWorklet context workletUrl
    liftEffect do
      recording <- N.uuid
      let size = segmentSeconds * Config.voiceSampleRate
          ratio = sampleRate context / I.toNumber Config.voiceSampleRate
      buffer <- allocate size
      carry <- allocate 0
      state <- Ref.new {buffer, filled: 0, index: 0, carry, position: 0.0}
      stopping <- Ref.new Nothing
      let
        emit final current = do
          data_ <- wav $ sliceSamples 0 current.filled current.buffer
          onSegment $ D.json {recording, index: current.index, final
            , startMs: Number.round $ I.toNumber (current.index * size) / Config.voiceSamplesPerMillisecond
            , durationMs: Number.round $ I.toNumber current.filled / Config.voiceSamplesPerMillisecond
            , mime: "audio/wav", data: data_}
          pure $ current {index = current.index + 1, filled = 0}
        receive samples = do
          current <- Ref.read state
          let input = appendSamples current.carry samples
          next <- tailRecM (\s -> if s.position + ratio > I.toNumber (sampleCount input) then pure $ Done s else do
            writeSample s.buffer s.filled $ average input (I.floor s.position) (I.floor $ s.position + ratio)
            let updated = s {filled = s.filled + 1, position = s.position + ratio}
            when (mod updated.filled Config.voiceSampleRate == 0) $
              onSecond $ I.toNumber (updated.index * size + updated.filled) / Config.voiceSamplesPerMillisecond
            advanced <- if updated.filled == size then emit false updated else pure updated
            pure $ Loop advanced) current
          let keep = I.floor next.position
          Ref.write (next {carry = sliceSamples keep (sampleCount input) input, position = next.position - I.toNumber keep}) state
      connection <- connectAudio context stream "s4-voice" receive
      pure {stop: do
        previous <- Ref.read stopping
        case previous of
          Just promise -> pure promise
          Nothing -> do
            promise <- fromAff do
              liftEffect $ disconnectAudio connection
              liftEffect $ stopTracks stream
              toAffE $ closeContext context
              liftEffect do
                current <- Ref.read state
                let durationMs = Number.round $ I.toNumber (current.index * size + current.filled) / Config.voiceSamplesPerMillisecond
                when (current.filled == 0) $ writeSample current.buffer 0 0.0
                next <- emit true $ current {filled = max 1 current.filled}
                Ref.write next state
                pure $ D.json {recording, segments: next.index, durationMs}
            Ref.write (Just promise) stopping
            pure promise}
  case result of
    Right voice -> pure voice
    Left failure -> do
      liftEffect $ stopTracks stream
      void $ attempt $ toAffE $ closeContext context
      throwError failure

voiceStop :: Voice -> Effect (Promise Json)
voiceStop voice = voice.stop

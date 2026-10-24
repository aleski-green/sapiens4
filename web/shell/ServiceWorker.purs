module Sapiens.ServiceWorker (main) where

import Prelude
import Data.Array (elem, filter)
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Data.String.CodeUnits (take)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Sapiens.Async (Promise, fromPromise, toPromise)

foreign import data Cache :: Type
foreign import data Event :: Type
foreign import data Request :: Type
foreign import data Response :: Type
foreign import listen :: String -> (Event -> Effect Unit) -> Effect Unit
foreign import waitUntil :: Event -> Promise Unit -> Effect Unit
foreign import respondWith :: Event -> Promise Response -> Effect Unit
foreign import openCache :: String -> Effect (Promise Cache)
foreign import addAll :: Array String -> Cache -> Effect (Promise Unit)
foreign import cacheKeys :: Effect (Promise (Array String))
foreign import deleteCache :: String -> Effect (Promise Boolean)
foreign import skipWaiting :: Effect (Promise Unit)
foreign import request :: Event -> Request
foreign import requestInfo :: Request -> { method :: String, origin :: String, pathname :: String, mode :: String }
foreign import origin :: String
foreign import matchPage :: Cache -> Effect (Promise (Nullable Response))
foreign import matchAsset :: Request -> Cache -> Effect (Promise (Nullable Response))
foreign import fetch :: Request -> Effect (Promise Response)

cacheName :: String
cacheName = "sapiens-shell-v1"

assets :: Array String
assets = [ "/", "/workspace/app.js", "/workspace/styles.css", "/live.css", "/corpora.css"
  , "/assets/sapi-theme.css", "/assets/sapi-theme.js", "/corpora.js", "/relay-servers.js"
  , "/remote-code.js", "/remote-session.js", "/remote-transport.js", "/remote-onboarding.js"
  , "/remote-install.js", "/remote-install.css", "/remote-vendor.js", "/manifest.webmanifest"
  , "/app-icon-180.png", "/app-icon-192.png", "/app-icon-512.png" ]

await :: forall a. Effect (Promise a) -> Aff a
await action = liftEffect action >>= fromPromise

cached :: Request -> Boolean -> Aff Response
cached req navigation = do
  cache <- await $ openCache cacheName
  response <- await $ if navigation then matchPage cache else matchAsset req cache
  case toMaybe response of
    Just value -> pure value
    Nothing -> await $ fetch req

main :: Effect Unit
main = do
  -- Activate only after the complete public shell has downloaded successfully.
  listen "install" \event -> do
    promise <- toPromise do
      cache <- await $ openCache cacheName
      await $ addAll assets cache
      await skipWaiting
    waitUntil event promise
  listen "activate" \event -> do
    promise <- toPromise do
      keys <- await cacheKeys
      traverse_ (\key -> void $ await $ deleteCache key)
        (filter (\key -> take 14 key == "sapiens-shell-" && key /= cacheName) keys)
    waitUntil event promise
  listen "fetch" \event -> do
    let
      req = request event
      info = requestInfo req
      public = info.method == "GET" && info.origin == origin && take 5 info.pathname /= "/api/"
      navigation = info.mode == "navigate"
    when (public && (navigation || elem info.pathname assets)) do
      response <- toPromise $ cached req navigation
      respondWith event response

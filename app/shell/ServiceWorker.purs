module Sapiens.ServiceWorker where

import Prelude
import Control.Promise (fromAff, toAffE)
import Data.Array as A
import Data.Foldable (traverse_)
import Data.String as S
import Effect (Effect)
import Effect.Aff (Aff)
import Sapiens.BrowserFFI as B
import Sapiens.Browser as Browser

cache :: String
cache = "sapiens-shell-v4"

assets :: Array String
assets = ["/", "/theme.js", "/favicon.svg", "/favicon-dark.svg", "/workspace/app.js", "/workspace/styles.css", "/live.css", "/corpora.css", "/assets/sapi-theme.css", "/remote-install.css", "/remote-vendor.js", "/remote-crypto.js", "/voice-worklet.js", "/manifest.webmanifest", "/app-icon-180.png", "/app-icon-192.png", "/app-icon-512.png", "/assets/fonts/dm-sans.woff2", "/assets/fonts/zen-maru-light.woff2", "/assets/fonts/zen-maru-medium.woff2", "/assets/fonts/ibm-plex-mono.woff2"]

main :: Effect Unit
main = do
  B.workerInstall "install" \_ -> fromAff do
    toAffE $ B.cacheAll cache assets
    toAffE B.activateWorker
  B.workerInstall "activate" \_ -> fromAff do
    keys <- toAffE B.cacheKeys
    traverse_ (toAffE <<< B.cacheDelete) (A.filter (\key -> key /= cache && S.take 14 key == "sapiens-shell-") keys)
  B.workerFetch (eligible <<< Browser.workerRequest) $ \raw -> fromAff $ execute $ response $ Browser.workerRequest raw

data Response = Cached String | Network String

eligible :: Browser.WorkerRequest -> Boolean
eligible r = r.method == "GET" && r.origin == r.localOrigin && S.take 5 r.path /= "/api/"

response :: Browser.WorkerRequest -> Response
response r
  | r.mode == "navigate" = Cached "/"
  | A.elem r.path assets = Cached r.url
  | otherwise = Network r.url

execute :: Response -> Aff B.Response
execute = case _ of
  Cached path -> toAffE $ B.cacheResponse cache path
  Network url -> toAffE $ B.fetchResponse url

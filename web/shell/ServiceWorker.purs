module Sapiens.ServiceWorker where

import Prelude
import Control.Promise (fromAff, toAffE)
import Data.Array as A
import Data.Foldable (traverse_)
import Data.String as S
import Effect (Effect)
import Libs4.Browser as B
import Sapiens.Data as D

cache :: String
cache = "sapiens-shell-v1"

assets :: Array String
assets = ["/", "/favicon.svg", "/favicon-dark.svg", "/workspace/app.js", "/workspace/styles.css", "/live.css", "/corpora.css", "/assets/sapi-theme.css", "/remote-install.css", "/remote-vendor.js", "/manifest.webmanifest", "/app-icon-180.png", "/app-icon-192.png", "/app-icon-512.png"]

main :: Effect Unit
main = do
  B.workerInstall "install" \_ -> fromAff do
    toAffE $ B.cacheAll cache assets
    toAffE B.activateWorker
  B.workerInstall "activate" \_ -> fromAff do
    keys <- toAffE B.cacheKeys
    traverse_ (toAffE <<< B.cacheDelete) (A.filter (\key -> key /= cache && S.take 14 key == "sapiens-shell-") keys)
  B.workerFetch (\r -> D.s "method" r == "GET" && D.s "origin" r == D.s "localOrigin" r && S.take 5 (D.s "path" r) /= "/api/") \request -> fromAff do
    if D.s "mode" request == "navigate" then toAffE $ B.cacheResponse cache "/"
    else if A.elem (D.s "path" request) assets then toAffE $ B.cacheResponse cache (D.s "url" request)
    else toAffE $ B.fetchResponse (D.s "url" request)

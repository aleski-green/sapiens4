module Sapiens.Application (main) where

import Prelude hiding (append, join)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Aff (Aff, try)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Sapiens.Async (toPromise)
import Sapiens.Artwork (brandSVG)
import Sapiens.Components as Components
import Sapiens.Runtime
import Sapiens.Session as Session
import Sapiens.Shell as Shell
import Sapiens.Text as T

brand :: Effect Unit
brand = do
  setField (global .! "document") "title" "Sapi4: Corpora"
  favicon <- element "link" "" ""
  setField favicon "rel" "icon"
  setField favicon "type" "image/svg+xml"
  let light = "data:image/svg+xml," <> T.encode brandSVG
      update = defer \_ -> setField favicon "href" $ if field "theme" (global .! "document" .! "documentElement" .! "dataset") == "dark" then T.replace (T.encode "fill=\"#fff\"") "" (T.encode "fill=\"#171717\"") light else light
  update
  append (global .! "document" .! "head") [favicon]
  void $ observe "MutationObserver" (global .! "document" .! "documentElement") (value {attributes:true,attributeFilter:["data-theme"]}) update

main :: Effect Unit
main = do
  ready <- toPromise initialize
  setField (global .! "window") "SapiensReady" ready

initialize :: Aff Unit
initialize = do
  result <- try do
    snapshot <- if boolean (global .! "window" .! "SapiensConnections") then await $ pure $ global .! "window" .! "SapiensConnections" .! "initial" else Session.api "/api/state" "GET" null
    liftEffect do
      write "bootstrap" snapshot
      write "live" snapshot
      Components.install
      brand
      Shell.mount
      for_ ["mountGroups", "mountActivity", "mountWork", "mountNames", "mountMentions", "mountWorkspace", "mountConversation", "mountComposer"] \name -> fire name []
      Session.mount
  case result of
    Right _ -> pure unit
    Left error -> liftEffect do
      host <- q "#corpora-startup-feedback"
      when (boolean host) do
        html host $ "<main style=\"padding:40px;font:16px monospace\"><h1>Sapiens4 could not connect</h1><p>" <> escape (message error) <> "</p><button>Retry connection</button></main>"
        qIn host "button" >>= \button -> on button "click" false $ const $ void $ call (global .! "location") "reload" []

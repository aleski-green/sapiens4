module Sapiens.Guest where

import Prelude
import Data.Argonaut.Core (Json)
import Data.Array as A
import Effect (Effect)
import Libs4.Browser as B
import Sapiens.Data as D

applyTheme :: Json -> Effect Json
applyTheme settings = do
  env <- B.environment
  let managed = D.s "href" env == "about:blank" || A.elem (D.s "contentType" env) ["text/plain","application/json","application/xml","text/xml"]
      dark = if D.valid $ D.get "dark" settings then D.b "dark" settings else D.b "dark" env
      background = D.fallback (if dark then "#000" else "#fff") $ D.s "background" settings
      foreground = D.fallback (if dark then "#eee" else "#171717") $ D.s "foreground" settings
  when managed $ B.styleSheet "sapiens-document-theme" $ "html,body{background:" <> background <> ";color:" <> foreground <> ";color-scheme:" <> (if dark then "dark" else "light") <> "}pre{white-space:pre-wrap;overflow-wrap:anywhere}"
  pure $ D.bool managed

main :: Effect Unit
main = do
  B.callbackResult "sapiensDocumentTheme" applyTheme
  void $ applyTheme D.empty

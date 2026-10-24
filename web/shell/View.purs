module Sapiens.View
  ( Nut, Attr, el, elNS, attr, on, text, text_, klass, mount, build, html, dispose, disposeContents ) where

import Prelude
import Data.Maybe (Maybe(..))
import Deku.Core (Attribute, elementify, attributeAtYourOwnRisk, callbackWithCaution)
import Deku.Core as Core
import Deku.Control (text_) as D
import Deku.Pursx (lenientPursx)
import Deku.SPA (runInElement)
import Effect (Effect)
import FRP.Poll (Poll)
import Sapiens.Browser as B
import Unsafe.Coerce (unsafeCoerce)

type Nut = Core.Nut

type Attr = Poll (Attribute ())

el :: String -> Array Attr -> Array Nut -> Nut
el = elementify Nothing

elNS :: String -> String -> Array Attr -> Array Nut -> Nut
elNS namespace = elementify (Just namespace)

attr :: String -> String -> Attr
attr name value = pure $ attributeAtYourOwnRisk name value

klass :: String -> Attr
klass = attr "class"

on :: String -> (B.Event -> Effect Unit) -> Attr
on name action = pure $ callbackWithCaution name (\event -> action (unsafeCoerce event) $> true)

text_ :: String -> Nut
text_ = D.text_

text :: String -> String -> String -> Nut
text tag className value = el tag [klass className] [text_ value]

-- Pursx handles trusted application templates. Dynamic user content must be
-- escaped by its producer or supplied as a text_ child. A slot keeps the parser
-- path (and full HTML attribute handling) for these multi-element fragments.
html :: String -> Nut
html source = lenientPursx ("<div style=\"display:contents\">" <> source <> "~end~</div>") { end: mempty :: Nut }

foreign import remember :: B.Element -> Effect Unit -> Effect Unit
foreign import rememberRoot :: B.Element -> Effect Unit -> Effect Unit
foreign import dispose :: B.Element -> Effect Unit
foreign import disposeContents :: B.Element -> Effect Unit
foreign import firstElement :: B.Element -> Effect B.Element

mount :: B.Element -> Nut -> Effect Unit
mount host view = do
  disposeContents host
  B.replaceChildren [] host
  cancel <- runInElement (unsafeCoerce host) view
  remember host cancel

-- Compatibility with callers that assemble a detached row before reconciliation.
-- The root owns its cancellation action, so replacing a containing view also
-- releases subscriptions created by nested components.
build :: Nut -> Effect B.Element
build view = do
  holder <- B.createElement "div"
  cancel <- runInElement (unsafeCoerce holder) view
  node <- firstElement holder
  rememberRoot node cancel
  pure node

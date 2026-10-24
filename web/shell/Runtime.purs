module Sapiens.Runtime where

import Prelude hiding (join)
import Data.Array as A
import Data.Foldable (foldMap)
import Data.Either (Either(..))
import Data.Maybe (fromMaybe)
import Data.String as S
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, try)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import Foreign (Foreign)
import Sapiens.Async (Promise, fromPromise, toPromise)
import Sapiens.Text as T
import Sapiens.View as V
import Unsafe.Coerce (unsafeCoerce)

-- JSON from the host and opaque platform handles share this boundary type.
-- Feature decisions remain in PureScript; the FFI only invokes platform APIs.
type Value = Foreign
foreign import null :: Value
foreign import global :: Value
foreign import get :: Value -> String -> Value
foreign import getE :: Value -> String -> Effect Value
foreign import defer :: forall a. (Unit -> Effect a) -> Effect a
foreign import set :: Value -> String -> Value -> Effect Unit
foreign import remove :: Value -> String -> Effect Unit
foreign import string :: Value -> String
foreign import boolean :: Value -> Boolean
foreign import number :: Value -> Number
foreign import int :: Value -> Int
foreign import array :: Value -> Array Value
foreign import keys :: Value -> Array String
foreign import object :: Array {key :: String, value :: Value} -> Value
foreign import merge :: Array Value -> Value
foreign import call :: Value -> String -> Array Value -> Effect Value
foreign import invoke :: Value -> Array Value -> Effect Value
foreign import callback :: (Array Value -> Effect Value) -> Value
foreign import constructible :: (Array Value -> Effect Value) -> Value
foreign import getter :: Value -> String -> Effect Value -> Effect Unit
foreign import kind :: Value -> String
foreign import parseE :: String -> Effect Value
foreign import decode64 :: String -> Effect Value
foreign import encode64 :: Value -> String
foreign import construct :: Value -> Array Value -> Effect Value
foreign import same :: Value -> Value -> Boolean
foreign import stringify :: Value -> String
foreign import pretty :: Value -> String
foreign import parse :: String -> Value
foreign import scope :: Effect Value
foreign import children :: Value -> Array Value
foreign import attributes :: Value -> Array {key :: String, value :: String}
foreign import readMarkup :: String -> Effect (Array Value)
foreign import now :: Effect Number
foreign import date :: String -> Value
foreign import dateNumber :: String -> Number
foreign import locale :: Value -> String -> Value -> String

value :: forall a. a -> Value
value = unsafeCoerce

infixl 9 get as .!

or :: Value -> Value -> Value
or a b = if boolean a then a else b

infixr 2 or as <||>

at :: Int -> Array Value -> Value
at index = fromMaybe null <<< flip A.index index

field :: String -> Value -> String
field key x = string $ x .! key

items :: String -> Value -> Array Value
items key x = array $ x .! key

find :: (Value -> Boolean) -> Array Value -> Value
find f = fromMaybe null <<< A.find f

has :: String -> Value -> Boolean
has key = A.elem key <<< keys

read :: String -> Effect Value
read key = scope <#> flip get key

write :: forall a. String -> a -> Effect Unit
write key x = scope >>= \s -> set s key (value x)

register :: String -> (Array Value -> Effect Value) -> Effect Unit
register name fn = write name $ callback fn

registerAsync :: String -> (Array Value -> Aff Value) -> Effect Unit
registerAsync name fn = register name (map value <<< toPromise <<< fn)

promise :: (Value -> Value -> Effect Unit) -> Effect Value
promise action = construct (global .! "Promise") [callback \args -> action (at 0 args) (at 1 args) $> null]

async :: (Array Value -> Aff Value) -> Value
async fn = callback (map value <<< toPromise <<< fn)

exec :: String -> Array Value -> Effect Value
exec name args = read name >>= flip invoke args

fire :: String -> Array Value -> Effect Unit
fire name = void <<< exec name

await :: Effect Value -> Aff Value
await action = liftEffect action >>= fromPromise <<< (unsafeCoerce :: Value -> Promise Value)

request :: String -> String -> Value -> Aff Value
request path method body = await $ exec "api" [value path, value method, body]

fetch :: String -> Aff Value
fetch path = request path "GET" null

report :: Aff Unit -> Effect Unit
report action = launchAff_ do
  result <- try action
  case result of
    Left error -> liftEffect $ fire "toast" [value $ message error]
    Right _ -> pure unit

q :: String -> Effect Value
q selector = call (global .! "document") "querySelector" [value selector]

qa :: String -> Effect (Array Value)
qa selector = qaIn (global .! "document") selector

qIn :: Value -> String -> Effect Value
qIn host selector = call host "querySelector" [value selector]

qaIn :: Value -> String -> Effect (Array Value)
qaIn host selector = call host "querySelectorAll" [value selector] <#> array

closest :: Value -> String -> Effect Value
closest node selector = call node "closest" [value selector]

setField :: forall a. Value -> String -> a -> Effect Unit
setField host name = set host name <<< value

prop :: forall a. String -> String -> a -> Effect Unit
prop selector name x = q selector >>= \node -> setField node name x

attr :: Value -> String -> String -> Effect Unit
attr node name text = void $ call node "setAttribute" [value name, value text]

getAttr :: Value -> String -> Effect String
getAttr node name = call node "getAttribute" [value name] <#> string

toggle :: Value -> String -> Boolean -> Effect Unit
toggle node name enabled = void $ call (node .! "classList") "toggle" [value name, value enabled]

style :: Value -> String -> String -> Effect Unit
style node name text = void $ call (node .! "style") "setProperty" [value name, value text]

focus :: Value -> Effect Unit
focus node = when (boolean node) $ void $ call node "focus" []

on :: Value -> String -> Boolean -> (Value -> Effect Unit) -> Effect Unit
on node name capture fn = void $ call node "addEventListener" [value name, callback (\args -> fn (at 0 args) $> null), value capture]

prevent :: Value -> Effect Unit
prevent event = void $ call event "preventDefault" []

stop :: Value -> Effect Unit
stop event = prevent event *> void (call event "stopImmediatePropagation" [])

delay :: Int -> Effect Unit -> Effect Value
delay ms action = call global "setTimeout" [callback (\_ -> action $> null), value ms]

cancelTimer :: Value -> Effect Unit
cancelTimer id = void $ call global "clearTimeout" [id]

frame :: Effect Unit -> Effect Value
frame action = call global "requestAnimationFrame" [callback (\_ -> action $> null)]

observe :: String -> Value -> Value -> Effect Unit -> Effect Value
observe kind node options action = do
  observer <- construct (global .! kind) [callback (\_ -> action $> null)]
  void $ call observer "observe" [node, options]
  pure observer

-- Dynamic templates are parsed at the browser boundary and rendered by Deku.
-- The fragment has no extra wrapper, preserving CSS, accessibility and sibling
-- identities relied on by native WebViews and transcript reconciliation.
markup :: Value -> V.Nut
markup node
  | int (node .! "nodeType") == 3 = V.text_ $ field "textContent" node
  | int (node .! "nodeType") /= 1 = mempty
  | otherwise = (if field "namespaceURI" node == "http://www.w3.org/1999/xhtml" then V.el else V.elNS (field "namespaceURI" node)) (field "localName" node)
      (map (\a -> V.attr a.key (if A.elem a.key ["checked", "disabled"] then "true" else a.value)) $ attributes node) (map markup $ children node)

html :: Value -> String -> Effect Unit
html host source = do
  nodes <- readMarkup source
  V.mount (unsafeCoerce host) (foldMap markup nodes)

putHTML :: String -> String -> Effect Unit
putHTML selector source = q selector >>= flip html source

element :: String -> String -> String -> Effect Value
element tag klass content = value <$> V.build (V.text tag klass content)

append :: Value -> Array Value -> Effect Unit
append host nodes = void $ call host "append" nodes

replaceChildren :: Value -> Array Value -> Effect Unit
replaceChildren host nodes = do
  V.disposeContents (unsafeCoerce host)
  void $ call host "replaceChildren" nodes

disposeTree :: Value -> Effect Unit
disposeTree = V.dispose <<< unsafeCoerce

escape :: String -> String
escape = T.escape

textOf :: Value -> String
textOf = field "textContent"

join :: Array String -> String
join = S.joinWith ""

stringMap :: Array Value -> (Value -> String) -> String
stringMap xs fn = join $ map fn xs

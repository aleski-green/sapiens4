module Sapiens.Html where

import Prelude
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Halogen as H
import Halogen.HTML as C
import Halogen.HTML.Properties as P
import Halogen.HTML.Events as E
import Sapiens.Action (Action(..))
import Web.Event.Event (Event, EventType(..))

type Html = H.ComponentHTML Action () Aff
type Prop = P.IProp () Action

node :: String -> Array Prop -> Array Html -> Html
node tag = C.element (C.ElemName tag)

keyed :: String -> Array Prop -> Array (Tuple String Html) -> Html
keyed tag = C.keyed (C.ElemName tag)

text :: String -> Html
text = C.text

attr :: String -> String -> Prop
attr name = P.attr (C.AttrName name)

bool :: String -> Boolean -> Prop
bool name = P.prop (C.PropName name)

value :: String -> Prop
value = P.prop (C.PropName "value")

cls :: String -> Prop
cls = attr "class"

id :: String -> Prop
id = attr "id"

label :: String -> Prop
label = attr "aria-label"

hidden :: Boolean -> Prop
hidden = bool "hidden"

disabled :: Boolean -> Prop
disabled = bool "disabled"

style :: String -> Prop
style = attr "style"

on :: String -> (Event -> Action) -> Prop
on name action = E.handler (EventType name) action

click :: Action -> Prop
click action = on "click" (const action)

input :: (String -> Action) -> Prop
input action = on "input" $ ValueInput action

change :: (String -> Action) -> Prop
change action = on "change" $ ValueInput action

check :: (Boolean -> Action) -> Prop
check action = on "change" $ CheckedInput action

submit :: Action -> Prop
submit action = on "submit" \event -> Submit event action

button :: String -> String -> Action -> Html
button classes caption action = node "button" [cls classes,attr "type" "button",click action] [text caption]

icon :: String -> String -> Action -> Html
icon caption glyph action = node "button" [cls "icon-button",attr "type" "button",label caption,attr "title" caption,click action] [text glyph]

div :: String -> Array Html -> Html
div classes = node "div" [cls classes]

p :: String -> String -> Html
p classes caption = node "p" [cls classes] [text caption]

empty :: Html
empty = text ""

when :: Boolean -> Html -> Html
when yes content = if yes then content else empty

field :: String -> String -> String -> Array Prop -> Html
field caption key current props = node "label" [] [text caption,node "input" ([attr "name" key,label caption,value current,input (Field key)] <> props) []]

textarea :: String -> String -> String -> Int -> Array Prop -> Html
textarea caption key current rows props = node "label" [] [text caption,node "textarea" ([attr "name" key,label caption,value current,attr "rows" (show rows),input (Field key)] <> props) []]

select :: String -> String -> String -> Array (Tuple String String) -> Html
select caption key current options = node "label" [] [text caption,node "select" [attr "name" key,label caption,value current,change (Field key)] (map option options)]
  where
  option pair = case pair of
    Tuple k v -> node "option" [value k,bool "selected" (k == current)] [text v]

link :: String -> String -> Html
link href caption = node "a" [attr "href" href,attr "target" "_blank",attr "rel" "noopener noreferrer"] [text caption]

module Sapiens.Browser
  ( Element, Event, MediaQuery, window, document, root, body, query, queryAll, closest
  , attribute, setAttribute, removeAttribute, hasAttribute, setText, text, setHTML
  , setProperty, property, setStyle, listen, target, preventDefault, stopImmediatePropagation
  , mediaQuery, matches, readStorage, writeStorage, expose, global, eventString
  , createElement, appendChildren, replaceChildren, addClass, focus, encodeURIComponent, writeClipboard
  ) where

import Prelude
import Effect (Effect)
import Sapiens.Async (Promise)
import Data.Nullable (Nullable)

-- Browser handles stay at the platform boundary; application decisions live in PureScript.
foreign import data Element :: Type
foreign import data Event :: Type
foreign import data MediaQuery :: Type
foreign import window :: Element
foreign import document :: Element
foreign import root :: Element
foreign import body :: Element
foreign import query :: String -> Element -> Effect (Nullable Element)
foreign import queryAll :: String -> Element -> Effect (Array Element)
foreign import closest :: String -> Element -> Effect (Nullable Element)
foreign import attribute :: String -> Element -> Effect (Nullable String)
foreign import setAttribute :: String -> String -> Element -> Effect Unit
foreign import removeAttribute :: String -> Element -> Effect Unit
foreign import hasAttribute :: String -> Element -> Effect Boolean
foreign import setText :: String -> Element -> Effect Unit
foreign import text :: Element -> Effect String
foreign import setHTML :: String -> Element -> Effect Unit
foreign import setProperty :: forall a. String -> a -> Element -> Effect Unit
foreign import property :: forall a. String -> Element -> Effect a
foreign import setStyle :: String -> String -> Element -> Effect Unit
foreign import listen :: forall a. String -> Boolean -> (Event -> Effect Unit) -> a -> Effect Unit
foreign import target :: Event -> Effect Element
foreign import eventString :: String -> Event -> Nullable String
foreign import preventDefault :: Event -> Effect Unit
foreign import stopImmediatePropagation :: Event -> Effect Unit
foreign import mediaQuery :: String -> Effect MediaQuery
foreign import matches :: MediaQuery -> Effect Boolean
foreign import readStorage :: String -> Effect (Nullable String)
foreign import writeStorage :: String -> String -> Effect Unit
foreign import expose :: forall a. String -> a -> Effect Unit
foreign import global :: forall a. String -> Effect (Nullable a)

foreign import createElement :: String -> Effect Element
foreign import appendChildren :: Array Element -> Element -> Effect Unit
foreign import replaceChildren :: Array Element -> Element -> Effect Unit
foreign import addClass :: String -> Element -> Effect Unit
foreign import focus :: Element -> Effect Unit
foreign import encodeURIComponent :: String -> String
foreign import writeClipboard :: String -> Effect (Promise Unit)

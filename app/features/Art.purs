module Sapiens.Art where

import Sapiens.Html as V

-- Decorative artwork is always hidden from assistive technology. Visible names
-- and status labels are supplied by the component that owns the artwork.
data Mood = Idle | Listening | Thinking | Working | Watching | Done | NeedsYou | Error | Asleep

face :: Mood -> String
face = case _ of
  Idle -> "(・ω・)"
  Listening -> "(・o・)"
  Thinking -> "(・へ・)"
  Working -> "φ(・ω・)"
  Watching -> "|・ω・)"
  Done -> "(＾▽＾)b"
  NeedsYou -> "(・∀・)ノ"
  Error -> "(；ω；)"
  Asleep -> "(－ω－) zzZ"

head :: Mood -> V.Html
head mood = V.node "span" [V.cls "sapi-face",V.attr "aria-hidden" "true"] [V.span [] (face mood)]

empty :: Mood -> V.Html
empty mood = V.node "div" [V.cls "empty-art",V.attr "aria-hidden" "true"] [head mood]

progress :: Mood -> V.Html
progress mood = V.node "div" [V.cls "typed-progress",V.attr "aria-hidden" "true"]
  [V.span [V.cls "progress-line"] "━━━━",head mood,V.span [] "━━━━"]

chiefy :: String -> V.Html
chiefy classes = V.svg "svg" [V.cls classes,V.attr "viewBox" "0 0 420 200",V.attr "fill" "none",V.attr "aria-hidden" "true",V.attr "focusable" "false"]
  [shape "path" [V.attr "d" "M70 14 Q14 100 70 186 H350 Q406 100 350 14 Z",V.attr "fill" "#fff"]
  ,shape "circle" [V.attr "cx" "165",V.attr "cy" "130",V.attr "r" "30",V.attr "fill" "#f8c0d6"]
  ,shape "circle" [V.attr "cx" "287",V.attr "cy" "130",V.attr "r" "30",V.attr "fill" "#f8c0d6"]
  ,shape "rect" [V.attr "x" "122",V.attr "y" "44",V.attr "width" "86",V.attr "height" "92",V.attr "rx" "18",V.attr "fill" "#111"]
  ,shape "rect" [V.attr "x" "244",V.attr "y" "44",V.attr "width" "86",V.attr "height" "92",V.attr "rx" "18",V.attr "fill" "#111"]
  ,shape "path" [V.attr "d" "M86 106 V86 H122",V.attr "stroke" "#111",V.attr "stroke-width" "9"]
  ,shape "path" [V.attr "d" "M213 142 H239 M70 14 Q14 100 70 186 M350 14 Q406 100 350 186",V.attr "stroke" "#111",V.attr "stroke-width" "6",V.attr "stroke-linecap" "round"]]
  where
  shape tag attrs = V.svg tag attrs []

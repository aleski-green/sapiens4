module Sapiens.Theme (main) where

import Prelude hiding (apply)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toMaybe)
import Effect (Effect)
import Effect.Ref as Ref
import Sapiens.Browser as Browser

data Theme = Light | Dark

themeName :: Theme -> String
themeName Light = "light"
themeName Dark = "dark"

parseTheme :: String -> Maybe Theme
parseTheme "light" = Just Light
parseTheme "dark" = Just Dark
parseTheme _ = Nothing

key :: String
key = "sapi-color-theme"

apply :: Theme -> Effect Unit
apply theme = do
  let dark = themeName theme == "dark"
  Browser.setAttribute "data-theme" (themeName theme) Browser.root
  Browser.setStyle "color-scheme" (themeName theme) Browser.root
  buttons <- Browser.queryAll "[data-theme-toggle]" Browser.document
  for_ buttons \button -> do
    let label = "Switch to " <> (if dark then "light" else "dark") <> " theme"
    Browser.setText (if dark then "☀" else "☾") button
    Browser.setAttribute "aria-label" label button
    Browser.setAttribute "title" label button
    Browser.setAttribute "aria-pressed" (if dark then "true" else "false") button

current :: Effect Theme
current = do
  value <- Browser.attribute "data-theme" Browser.root
  pure $ fromMaybe Light (toMaybe value >>= parseTheme)

main :: Effect Unit
main = do
  existing <- Browser.global "SapiTheme"
  case toMaybe existing of
    Just (api :: { refresh :: Effect Unit }) -> api.refresh
    Nothing -> do
      stored <- Browser.readStorage key
      preference <- Ref.new (toMaybe stored)
      system <- Browser.mediaQuery "(prefers-color-scheme: dark)"
      let
        preferred = do
          value <- Ref.read preference
          dark <- Browser.matches system
          pure $ fromMaybe (if dark then Dark else Light) (value >>= parseTheme)
        refresh = current >>= apply
      Browser.expose "SapiTheme" { refresh }
      preferred >>= apply
      Browser.listen "click" false (\event -> do
        element <- Browser.target event
        button <- Browser.closest "[data-theme-toggle]" element
        for_ (toMaybe button) \_ -> do
          previous <- current
          let next = if themeName previous == "dark" then Light else Dark
          Ref.write (Just $ themeName next) preference
          apply next
          Browser.writeStorage key (themeName next)
        ) Browser.document
      Browser.listen "storage" false (\event ->
        when (toMaybe (Browser.eventString "key" event) == Just key) do
          Ref.write (toMaybe $ Browser.eventString "newValue" event) preference
          preferred >>= apply
        ) Browser.window
      Browser.listen "change" false (\_ -> do
        value <- Ref.read preference
        when (value == Nothing || value == Just "") (preferred >>= apply)
        ) system

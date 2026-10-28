module Main where

import qualified Data.Text as T
import Application
import Icon
import System.Environment

main = do
    arguments <- getArgs
    case arguments of
        ["--fixture", address] -> runApplication True (T.pack address)
        [address] | take 4 address == "http" -> runApplication True (T.pack address)
        ["--icon", directory, source] -> createIcon directory source
        [] -> runApplication False (T.pack "http://127.0.0.1:4174")
        _ -> ioError (userError "Usage: sapiens-macos [--fixture URL | --icon DIRECTORY SVG]")

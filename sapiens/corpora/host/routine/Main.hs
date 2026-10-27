module Main (main) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as Bytes
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hSetEncoding, hSetNewlineMode, noNewlineTranslation, stdin, utf8)
import Wire (response)

main :: IO ()
main = do
    args <- getArgs
    attached <- case args of
        ["routine", "0"] -> pure False
        ["routine", "1"] -> pure True
        _ -> die "Usage: sapiens-domain routine 0|1"
    hSetEncoding stdin utf8
    hSetNewlineMode stdin noNewlineTranslation
    text <- getContents
    Bytes.putStrLn (encode (response attached text))

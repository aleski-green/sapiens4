module Main where

import Control.Exception
import Control.Monad
import Data.Aeson
import qualified Data.Text as T
import System.Directory
import System.Environment
import System.FilePath
import System.FileLock
import Types (readJSON,writeJSON,get,items,text)
import BuildVersion
import RuntimePaths (containedPath)
import qualified V00_02_00

-- Ordered BUILD transitions. A script can transform any part of Data or Config;
-- the runner knows nothing about SQLite, JSON, LMDB or their schema versions.
transitions :: [(String,String,FilePath -> FilePath -> IO ())]
transitions = [("v00.01.00","v00.02.00",V00_02_00.migrate)]

main :: IO ()
main = do
 args <- getArgs
 case args of
  ["--data-root",root,"--config-root",config] -> do
   absoluteRoot <- canonicalizePath root
   absoluteConfig <- canonicalizePath config
   migrateTree absoluteRoot absoluteConfig
  _ -> fail "Usage: sapiens-migrate --data-root DATA --config-root CONFIG (all app processes stopped; verified backup required)"

migrateTree :: FilePath -> FilePath -> IO ()
migrateTree root config = bracket
 (tryLockFile (root </> "host.lock") Exclusive >>= maybe (fail "Stop all writers before migration") pure)
 unlockFile $ \_ -> do
  saved <- readJSON (root </> dataBuildFile) legacyBuild
  chain <- either fail pure (migrationPath saved currentBuild)
  registry <- readJSON (root </> "host-corpora.json") Null
  forM_ (items registry "locals") $ \identity -> do
   let ident=T.unpack (text identity)
   unless (not (null ident) && takeFileName ident==ident && ident/=".." && all (`elem` (['0'..'9']++['a'..'f']++"-")) ident) (fail "Invalid child corpora identity")
   child <- containedPath root (root </> "corporas" </> ident)
   migrateTree child config
  forM_ chain $ \(target,script) -> do
   script root config
   writeJSON (root </> dataBuildFile) target

migrationPath :: String -> String -> Either String [(String,FilePath -> FilePath -> IO ())]
migrationPath from target = go [] from
 where
 go seen version
  | version==target = Right []
  | version `elem` seen = Left "Cyclic build migration chain"
  | otherwise = case [(next,script) | (previous,next,script)<-transitions,previous==version] of
     [(next,script)] -> ((next,script):) <$> go (version:seen) next
     _ -> Left ("No unambiguous migration from "++version++" to "++target)

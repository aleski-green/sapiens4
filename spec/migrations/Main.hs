module Main where
import qualified Append4 as A
import Control.Concurrent (threadDelay)
import System.IO (stdout, hFlush)
import Control.Exception
import Control.Monad
import Data.Aeson
import qualified Data.Text
import qualified Data.ByteString.Lazy.Char8 as L
import MigrationPlan
import MigrationVersion
import qualified Migrations
import qualified V00_02_01 as Lifecycle
import System.Environment

main :: IO ()
main = do
 args <- getArgs
 case args of
  ["corpora",root] -> dump (Migrations.openCorpora root)
  ["relay",path] -> dump (Migrations.openRelay path)
  ["plan",path] -> checkPlan path
  ["inspect",path] -> dump (A.openStore path)
  ["crash",path] -> bracket (A.openStore path) A.closeStore $ \store -> do
   A.putValue store versionKey (String (versionText baselineVersion))
   A.transaction store $ do
    A.putValue store "partial" (Bool True)
    A.putValue store versionKey (String (versionText currentVersion))
    putStrLn "READY"
    hFlush stdout
    forever (threadDelay 1000000)
  ["seed",path,input] -> do
   entries <- L.readFile input >>= either fail pure . eitherDecode
   bracket (A.openStore path) A.closeStore $ \store -> A.transaction store $
    mapM_ (uncurry (A.putValue store)) (entries :: [(Data.Text.Text,Value)])
  ["crash-cleanup",path] -> bracket (A.openStore path) A.closeStore $ \store ->
   runMigrations [Migration Lifecycle.sourceVersion Lifecycle.targetVersion (\s -> do
    Lifecycle.corpora s
    putStrLn "READY"
    hFlush stdout
    forever (threadDelay 1000000))] Lifecycle.sourceVersion Lifecycle.targetVersion store
  ["set-version",path,value] -> bracket (A.openStore path) A.closeStore $ \store -> A.putValue store versionKey (toJSON value)
  _ -> fail "corpora ROOT | relay PATH | plan PATH | set-version PATH VERSION"
 where dump open = bracket open A.closeStore (A.readSnapshot >=> L.putStrLn . encode . A.entries)

checkPlan :: FilePath -> IO ()
checkPlan path = bracket (A.openStore path) A.closeStore $ \store -> do
 let current=AppVersion "v00.02.00"
     next=AppVersion "v00.02.01"
     later=AppVersion "v00.02.02"
     first=Migration baselineVersion current (\s -> A.putValue s "first" (Bool True))
     second=Migration current next (\s -> A.getValue s "first" >>= \v -> unless (v==Just (Bool True)) (fail "order") >> A.putValue s "second" (Bool True))
     failing=Migration next later (\s -> A.putValue s "partial" (Bool True) >> fail "injected failure")
     steps=[second,first,failing]
     denied result=case result of Left _ -> pure (); Right _ -> fail "invalid plan accepted"
 denied (plan [first] baselineVersion next)
 denied (plan [first,first] baselineVersion current)
 denied (plan [] next current)
 A.putValue store versionKey (String (versionText baselineVersion))
 result <- try (runMigrations steps baselineVersion later store) :: IO (Either IOException ())
 case result of Left _ -> pure (); Right _ -> fail "failure swallowed"
 version <- A.getValue store versionKey
 partial <- A.getValue store "partial"
 unless (version==Just (String (versionText next)) && partial==Nothing) $ fail "failed step was partially committed"
 let fixed=Migration next later (\s -> A.putValue s "third" (Bool True))
 runMigrations [fixed] next later store
 before <- A.readSnapshot store
 runMigrations [fixed] later later store
 after <- A.readSnapshot store
 unless (before==after) $ fail "repeat changed state"
 putStrLn "PASS sequential steps, rollback, resume, no-op, gaps, ambiguity, downgrade"

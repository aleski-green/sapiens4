module PulseClock (register, periodMicros) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.IORef
import qualified Data.Map.Strict as M
import GHC.Clock
import System.IO
import System.IO.Unsafe (unsafePerformIO)

periodMicros :: Int
periodMicros = 500000
-- Exactly one 120 BPM clock per host process, shared by all local corpora.
{-# NOINLINE clock #-}
clock :: MVar (Int, M.Map Int (IO ()), Maybe (Async ()))
clock = unsafePerformIO (newMVar (0,M.empty,Nothing))
register :: IO () -> IO (IO ())
register tick = modifyMVar clock $ \(serial,callbacks,worker) -> do
 let identity=serial+1
 next <- case worker of Just running -> pure running; Nothing -> async loop
 pure ((identity,M.insert identity tick callbacks,Just next),unregister identity)
 where
 loop = do
  start <- getMonotonicTimeNSec
  forever $ do
   now <- getMonotonicTimeNSec
   let period=fromIntegral periodMicros*1000
       next=start+((now-start) `div` period+1)*period
   threadDelay (fromIntegral ((next-now) `div` 1000))
   callbacks <- (\(_,xs,_) -> M.elems xs) <$> readMVar clock
   forM_ callbacks $ \action -> action `catch` \(e::SomeException) -> case fromException e :: Maybe SomeAsyncException of
    Just _ -> throwIO e
    Nothing -> hPutStrLn stderr ("Pulse failed: "++displayException e)
 unregister identity = do
  stopped <- modifyMVar clock $ \(serial,callbacks,worker) -> do
   let remaining=M.delete identity callbacks
   pure ((serial,remaining,if M.null remaining then Nothing else worker),if M.null remaining then worker else Nothing)
  mapM_ cancel stopped

module BrowserCrypto where

import Types
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM hiding (check)
import qualified Control.Concurrent.STM as STM
import Control.Exception
import Control.Monad
import Data.Aeson (Value, encode, eitherDecode)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Network.WebSockets as WS
import System.Timeout (timeout)

data PendingCrypto = PendingCrypto Int (TMVar (Either APIError Value))
data BrowserCrypto = BrowserCrypto
 { cryptoSerial :: TVar Int
 , cryptoWindows :: TVar (M.Map Int (TQueue Value))
 , cryptoPending :: TVar (M.Map Text PendingCrypto)
 }

newBrowserCrypto :: IO BrowserCrypto
newBrowserCrypto = BrowserCrypto <$> newTVarIO 0 <*> newTVarIO M.empty <*> newTVarIO M.empty

windowRequired :: APIError
windowRequired = APIError 503 "Keep a Sapiens4 window open for remote control."

nextSerial :: BrowserCrypto -> STM Int
nextSerial crypto = do
 n <- readTVar (cryptoSerial crypto)
 writeTVar (cryptoSerial crypto) (n+1)
 pure n

browserConnected :: BrowserCrypto -> IO Bool
browserConnected crypto = not . M.null <$> readTVarIO (cryptoWindows crypto)

awaitBrowser :: BrowserCrypto -> IO ()
awaitBrowser crypto = atomically $ readTVar (cryptoWindows crypto) >>= STM.check . not . M.null

requireBrowser :: BrowserCrypto -> IO ()
requireBrowser crypto = browserConnected crypto >>= \connected -> unless connected (throwIO windowRequired)

browserCall :: BrowserCrypto -> Text -> Value -> IO Value
browserCall crypto operation input = mask $ \restore -> do
 (identity,answer) <- atomically $ do
  windows <- readTVar (cryptoWindows crypto)
  (owner,queue) <- maybe (throwSTM windowRequired) pure (M.lookupMin windows)
  pending <- readTVar (cryptoPending crypto)
  when (M.size pending >= 8) (throwSTM (APIError 503 "Remote crypto is busy. Try again."))
  identity <- T.pack . show <$> nextSerial crypto
  answer <- newEmptyTMVar
  writeTVar (cryptoPending crypto) (M.insert identity (PendingCrypto owner answer) pending)
  writeTQueue queue (obj [("id",str identity),("operation",str operation),("input",input)])
  pure (identity,answer)
 result <- restore (timeout 15000000 (atomically $ takeTMVar answer))
  `finally` atomically (modifyTVar' (cryptoPending crypto) (M.delete identity))
 maybe (throwIO windowRequired) (either throwIO pure) result

cryptoSocket :: BrowserCrypto -> WS.ServerApp
cryptoSocket crypto pending = do
 conn <- WS.acceptRequest pending
 let register = atomically $ do
      identity <- nextSerial crypto
      queue <- newTQueue
      modifyTVar' (cryptoWindows crypto) (M.insert identity queue)
      pure (identity,queue)
     unregister (identity,_) = atomically $ do
      modifyTVar' (cryptoWindows crypto) (M.delete identity)
      jobs <- readTVar (cryptoPending crypto)
      forM_ (M.elems jobs) $ \(PendingCrypto owner answer) ->
       when (owner==identity) (void $ tryPutTMVar answer (Left windowRequired))
     send queue = forever $ do
      job <- atomically $ readTQueue queue
      active <- M.member (at job "id") <$> readTVarIO (cryptoPending crypto)
      when active (WS.sendTextData conn (encode job))
     receive identity = forever $ do
      raw <- WS.receiveData conn
      value <- either (const $ failure 400 "Invalid browser crypto response") pure (eitherDecode raw)
      atomically $ do
       jobs <- readTVar (cryptoPending crypto)
       case M.lookup (at value "id") jobs of
        Just (PendingCrypto owner answer) | owner==identity -> do
         let result = if boolean (get value "ok") then Right (get value "result") else Left (APIError 400 "Invalid encrypted message")
         void $ tryPutTMVar answer result
        _ -> pure ()
 (bracket register unregister $ \(identity,queue) ->
  WS.withPingThread conn 20 (pure ()) $ race_ (send queue) (receive identity))
  `catch` \(_::WS.ConnectionException) -> pure ()

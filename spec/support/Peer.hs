{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.List (findIndex)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign hiding (void)
import Foreign.C
import Network.URI (URI(..), URIAuth(..), parseURI)
import qualified Network.WebSockets as WS
import qualified Wuss
import System.IO
import System.Timeout

foreign import ccall unsafe "sodium_init" initialize :: IO CInt
foreign import ccall unsafe "randombytes_buf" randomBytes :: Ptr Word8 -> CSize -> IO ()
foreign import ccall unsafe "crypto_box_keypair" keypair :: Ptr Word8 -> Ptr Word8 -> IO CInt
foreign import ccall unsafe "crypto_scalarmult_base" publicKey :: Ptr Word8 -> Ptr Word8 -> IO CInt
foreign import ccall unsafe "crypto_box_easy" encrypt :: Ptr Word8 -> Ptr Word8 -> CULLong -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> IO CInt
foreign import ccall unsafe "crypto_box_open_easy" decrypt :: Ptr Word8 -> Ptr Word8 -> CULLong -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> IO CInt

field :: Value -> Text -> Value
field (Object values) key = fromMaybe Null $ KM.lookup (K.fromText key) values
field _ _ = Null
text :: Value -> Text
text (String value) = value
text _ = ""
withBytes :: B.ByteString -> (Ptr Word8 -> IO a) -> IO a
withBytes bytes action = B.useAsCString bytes (action . castPtr)
encoded :: B.ByteString -> Value
encoded = String . TE.decodeUtf8 . Base64.encode
raw :: Value -> IO B.ByteString
raw value = either (ioError . userError) pure $ Base64.decode $ TE.encodeUtf8 $ text value
merge :: Value -> Value -> Value
merge (Object base) (Object extra) = Object (KM.union extra base)
merge value _ = value
checked :: CInt -> IO ()
checked code = unless (code == 0) $ ioError $ userError "NaCl operation failed"

keys :: IO Value
keys = allocaBytes 32 $ \public -> allocaBytes 32 $ \private -> do
 keypair public private >>= checked
 secret <- B.packCStringLen (castPtr private,32)
 visible <- B.packCStringLen (castPtr public,32)
 pure $ object ["private" .= encoded secret,"public" .= encoded visible]

crypt :: Bool -> Value -> IO Value
crypt unpack input = do
 secret <- raw (field input "private")
 peer <- raw (field input "public")
 unless (B.length secret == 32 && B.length peer == 32) $ ioError $ userError "Invalid NaCl key length"
 withBytes secret $ \private -> withBytes peer $ \public -> if unpack then do
  let frame = field input "frame"
  cipher <- raw (field frame "ciphertext")
  nonce <- raw (field frame "nonce")
  unless (B.length nonce == 24 && B.length cipher >= 16) $ ioError $ userError "Invalid NaCl ciphertext"
  withBytes cipher $ \encrypted -> withBytes nonce $ \random -> allocaBytes (B.length cipher - 16) $ \plain -> do
   decrypt plain encrypted (fromIntegral $ B.length cipher) random public private >>= checked
   bytes <- B.packCStringLen (castPtr plain,B.length cipher - 16)
   either (ioError . userError) pure (eitherDecodeStrict bytes)
 else allocaBytes 24 $ \nonce -> allocaBytes 32 $ \sender -> do
  randomBytes nonce 24
  publicKey sender private >>= checked
  let body = merge (object ["v" .= ("sapiens-remote-box-v1" :: Text),"room" .= field input "room","direction" .= ("phone-to-desktop" :: Text)]) (field input "body")
      bytes = BL.toStrict $ encode body
  withBytes bytes $ \plain -> allocaBytes (B.length bytes + 16) $ \cipher -> do
   encrypt cipher plain (fromIntegral $ B.length bytes) nonce public private >>= checked
   ciphertext <- B.packCStringLen (castPtr cipher,B.length bytes + 16)
   nonceBytes <- B.packCStringLen (castPtr nonce,24)
   senderBytes <- B.packCStringLen (castPtr sender,32)
   pure $ object ["sender" .= encoded senderBytes,"nonce" .= encoded nonceBytes,"ciphertext" .= encoded ciphertext]

data Peer = Peer { connection :: WS.Connection, worker :: Async (), messages :: TVar [Value], closed :: TVar (Maybe Value) }

connect :: Value -> IO Peer
connect input = do
 uri <- maybe (ioError $ userError "Invalid peer URL") pure (parseURI $ T.unpack $ text $ field input "url")
 authority <- maybe (ioError $ userError "Missing peer host") pure (uriAuthority uri)
 let secure = uriScheme uri == "https:"
     host = filter (`notElem` ("[]" :: String)) (uriRegName authority)
     port = if null (uriPort authority) then (if secure then 443 else 80) else read (drop 1 $ uriPort authority)
     origin = if field input "origin" == Null then field input "url" else field input "origin"
     headers = [("Origin",TE.encodeUtf8 $ text origin)]
     options = WS.defaultConnectionOptions {WS.connectionMessageDataSizeLimit=WS.SizeLimit 24000000}
 ready <- newEmptyMVar
 queue <- newTVarIO []
 end <- newTVarIO Nothing
 let application socket = do
      WS.sendTextData socket $ encode $ object ["type" .= ("auth" :: Text),"room" .= field input "room","token" .= field input "token"]
      putMVar ready (Right socket)
      forever $ do
       bytes <- WS.receiveData socket :: IO BL.ByteString
       value <- either (ioError . userError) pure (eitherDecode bytes)
       atomically $ modifyTVar' queue (++ [value])
     connectSocket = if secure then Wuss.runSecureClientWith host (fromIntegral port) "/api/socket" options headers application
      else WS.runClientWith host port "/api/socket" options headers application
     ended (errorValue :: SomeException) = do
      void $ tryPutMVar ready (Left errorValue)
      let (code,detail) = case fromException errorValue of
           Just (WS.CloseRequest number _) -> (fromIntegral number :: Int,Null)
           _ -> (1006,String $ T.pack $ displayException errorValue)
      atomically $ writeTVar end $ Just $ object ["closed" .= code,"error" .= detail]
 job <- async (connectSocket `catch` ended)
 result <- timeout 5000000 $ takeMVar ready
 case result of
  Just (Right socket) -> pure $ Peer socket job queue end
  Just (Left errorValue) -> cancel job >> throwIO errorValue
  Nothing -> cancel job >> ioError (userError "WebSocket connection timed out")

readPeer :: Peer -> Int -> Maybe Text -> IO Value
readPeer peer microseconds request = fromMaybe Null <$> timeout microseconds (atomically $ do
 queue <- readTVar (messages peer)
 let matches item = maybe True (\identity -> field item "type" == String "result" && field item "id" == String identity) request
 case findIndex matches queue of
  Just index -> do
   case splitAt index queue of
    (before,item:after) -> writeTVar (messages peer) (before ++ after) >> pure item
    _ -> retry
  Nothing -> readTVar (closed peer) >>= maybe retry pure)

closePeer :: Peer -> IO ()
closePeer peer = do
 done <- poll (worker peer)
 when (isNothing done) $ void (timeout 1000000 $ WS.sendClose (connection peer) ("" :: Text)) `catch` \(_::SomeException) -> pure ()
 result <- timeout 5000000 $ waitCatch (worker peer)
 when (isNothing result) $ cancel (worker peer) >> ioError (userError "WebSocket fixture did not stop")

run :: IORef (M.Map Text Peer) -> IORef Int -> Value -> IO Value
run peers serial input = case text (field input "op") of
 "keys" -> keys
 "pack" -> crypt False input
 "unpack" -> crypt True input
 "connect" -> do
  current <- readIORef peers
  mapM_ closePeer (M.lookup name current)
  peer <- connect input
  modifyIORef' peers (M.insert name peer)
  readPeer peer 5000000 Nothing
 op -> do
  current <- readIORef peers
  peer <- maybe (ioError $ userError "Unknown peer") pure (M.lookup name current)
  case op of
   "status" -> fromMaybe (object ["closed" .= Null,"error" .= Null]) <$> readTVarIO (closed peer)
   "close" -> closePeer peer >> pure (Bool True)
   "read" -> let duration = case field input "timeout" of Number value -> round (value * 1000); _ -> 5000000 in readPeer peer duration Nothing
   "call" -> do
    number <- atomicModifyIORef' serial (\number -> (number+1,number+1))
    let request = T.pack $ show number
    WS.sendTextData (connection peer) $ encode $ merge (object ["id" .= request]) (field input "body")
    readPeer peer 5000000 (Just request)
   _ -> ioError $ userError $ "Unknown operation: " ++ T.unpack op
 where name = text (field input "name")

main :: IO ()
main = do
 initialize >>= \status -> when (status < 0) $ ioError $ userError "Cannot initialize NaCl"
 peers <- newIORef M.empty
 serial <- newIORef 0
 hSetBuffering stdout LineBuffering
 let loop = do
      done <- hIsEOF stdin
      unless done $ do
       line <- BC.hGetLine stdin
       result <- try $ either (ioError . userError) (run peers serial) (eitherDecodeStrict line)
       BL.hPutStr stdout $ encode $ case result of
        Right value -> object ["value" .= value]
        Left (errorValue :: SomeException) -> object ["error" .= displayException errorValue]
       hPutChar stdout '\n'
       loop
 loop `finally` (readIORef peers >>= mapM_ (\peer -> closePeer peer `catch` \(_::SomeException) -> pure ()))

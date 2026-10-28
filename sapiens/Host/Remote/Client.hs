module Host.Remote.Client where

import State.Types
import Host.Remote.Crypto
import Host.Remote.Transport
import Control.Concurrent.MVar
import Control.Concurrent.Async (AsyncCancelled)
import Control.Exception
import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.ByteString.Lazy as BL
import Data.Char
import Data.IORef
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.UUID as UUID
import System.Info
import System.Environment


data Client = Client { clientConfig :: MVar Value, clientSocket :: MVar (Maybe SocketClient), clientGuard :: MVar (), clientRevoked :: IORef Bool, clientConnection :: IORef Text }
newClient :: Value -> IO Client
newClient config = Client <$> newMVar config <*> newMVar Nothing <*> newMVar () <*> newIORef False <*> newIORef ""
closeClient :: Client -> IO ()
closeClient c = modifyMVar_ (clientSocket c) $ \socket -> mapM_ closeSocket socket >> pure Nothing
revokeClient :: Client -> IO ()
revokeClient c = writeIORef (clientRevoked c) True >> closeClient c
exchange :: Client -> Value -> Double -> IO Value
exchange c payload duration = withMVar (clientGuard c) $ \_ -> do
 revoked <- readIORef (clientRevoked c)
 require (not revoked) 410 "Remote connection was revoked"
 config <- readMVar (clientConfig c)
 currentSocket <- readMVar (clientSocket c)
 case currentSocket of
  Nothing -> newId >>= writeIORef (clientConnection c)
  Just _ -> pure ()
 ident <- newId
 time <- seconds
 connection <- readIORef (clientConnection c)
 hostname <- maybe "" T.pack <$> lookupEnv "HOSTNAME"
 let body = merge (obj [("id",str ident),("expires",toJSON (time+duration)),("corpora_id",get (get config "corpora") "id"),("connection_id",str connection),
             ("device_info",obj [("name",str hostname),("platform",str (T.pack os)),("client",str "Sapiens4 desktop")])]) payload
 frame <- pack (get config "private") (get config "desktop") (at config "room") PhoneToDesktop body
 let transport action = action `catch` \(APIError _ message) -> ioError (userError $ T.unpack message)
     unreachable (errorValue::SomeException) = case fromException errorValue :: Maybe SomeAsyncException of
      Just _ -> throwIO errorValue
      Nothing -> case fromException errorValue :: Maybe AsyncCancelled of
       Just _ -> throwIO errorValue
       Nothing -> closeClient c >> failure 503 "This device is unreachable. Try again later."
 (do
  socket <- transport $ modifyMVar (clientSocket c) $ \existing -> case existing of
   Just socket -> pure (existing,socket)
   Nothing -> do
    socket <- openSocket config
    pure (Just socket,socket)
  nowRevoked <- readIORef (clientRevoked c)
  when nowRevoked (closeClient c >> failure 410 "Remote connection was revoked")
  void $ transport $ socketCall socket (SendFrame frame)
  let wait = do
       nowTime <- seconds
       unless (nowTime < time+duration) $ ioError (userError "Host did not respond")
       incoming <- transport (socketReceive socket)
       case incoming of
        Nothing -> wait
        Just item -> do
         decoded <- try (unpack (get config "private") (get config "desktop") (at config "room") DesktopToPhone (get item "frame"))
         void $ transport $ socketCall socket (AckMessage (get item "id"))
         case decoded of
          Right response | at response "id"==ident && at response "kind"=="response" -> do
           let result = get response "result"
           require (T.null (at result "error")) 409 (at result "error")
           pure result
          Left (_::APIError) -> wait
          _ -> wait
  wait) `catches` [Handler (\(e::APIError) -> throwIO e),Handler unreachable]
clientRequest :: Client -> Text -> Text -> Maybe Value -> IO (Int,BL.ByteString,Text)
clientRequest c method path body = do
 result <- exchange c (obj [("kind",str "request"),("op",str "api"),("method",str method),("path",str path),("data",maybe Null id body)]) 12
 raw <- if boolean (get result "binary") then BL.fromStrict <$> unb64 (get result "body") Nothing else pure (encode (get result "body"))
 pure (int (get result "status"),raw,at result "mime")
invitation :: Value -> IO Client
invitation value = do
 require (at value "v"==protocol) 400 "Invalid pairing invitation"
 relay <- origin (get value "relay")
 forM_ ["room","token","secret"] $ \field -> do
  let input = at value field
  require (T.length input>=32 && T.length input<=64 && T.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("_-"::String))) input) 400 "Invalid pairing invitation"
 time <- seconds
 let expiry = case get value "expires" of Number n -> realToFrac n; _ -> 0
 require (time<expiry && expiry<=time+fromIntegral pairingTTL+60) 400 "Invitation expired. Show a new QR on the host."
 void (unb64 (get value "desktop") (Just 32))
 (private,public) <- keypair
 newClient (obj [("relay",str relay),("room",get value "room"),("token",get value "token"),("desktop",get value "desktop"),("private",str private),("public",str public)])
pairClient :: Client -> Value -> IO Value
pairClient c value = do
 time <- seconds
 let expiry = case get value "expires" of Number n -> realToFrac n; _ -> 0
 result <- exchange c (obj [("kind",str "pair"),("secret",get value "secret")]) (min 180 (expiry-time))
 let corpora = get result "corpora"; identity = at corpora "id"
 require (boolean (get result "paired") && maybe False ((==identity) . UUID.toText) (UUID.fromText identity)) 409 "Corpora identity could not be verified"
 modifyMVar_ (clientConfig c) (pure . put "corpora" corpora)
 pure corpora

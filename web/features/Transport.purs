module Sapiens.Transport (main) where

import Prelude hiding (append, join)
import Control.Lazy as Lazy
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, try)
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import Effect.Exception as Exception
import Sapiens.Runtime
import Sapiens.Text as T

unreachable :: String
unreachable = "This device is unreachable. Try again later."

bytes :: String -> Int -> Effect Value
bytes source size = do
  data_ <- decode64 source
  when (size /= 0 && int (data_ .! "length") /= size) $ throw "Invalid key"
  pure data_

clearSession :: Value -> Effect Unit
clearSession session = when (boolean $ session .! "corpora") $ launchAff_ $ void $ try $ await do
  let api = global .! "window" .! "RemoteSession"
  key <- call api "key" [session]
  call api "clear" [key]

rejectPending :: Value -> Value -> Effect Unit
rejectPending client error = do
  for_ (keys $ client .! "pending") \id -> void $ call (client .! "pending" .! id) "reject" [error]
  setField client "pending" {}

consume :: Value -> Value -> Effect Unit
consume client item = do
  let session = client .! "session"
      frame = item .! "frame"
      nacl = global .! "window" .! "RemoteVendor" .! "nacl"
  when (same (frame .! "sender") (session .! "desktop")) do
    cipher <- bytes (field "ciphertext" frame) 0
    nonce <- bytes (field "nonce" frame) 24
    desktop <- bytes (field "desktop" session) 32
    plain <- call (nacl .! "box") "open" [cipher,nonce,desktop,session .! "keys" .! "secretKey"]
    when (boolean plain) do
      decoder <- construct (global .! "TextDecoder") []
      source <- call decoder "decode" [plain]
      message_ <- parseE $ string source
      finite <- call (global .! "Number") "isFinite" [message_ .! "expires"]
      time <- (_ / 1000.0) <$> now
      when (field "v" message_ == "sapiens-remote-box-v1" && same (message_ .! "room") (session .! "room") && field "direction" message_ == "desktop-to-phone" && field "kind" message_ == "response" && boolean finite && number (message_ .! "expires") > time && number (message_ .! "expires") <= time + 86400.0) do
        let pending = client .! "pending" .! field "id" message_
        when (boolean pending) do
          remove (client .! "pending") $ field "id" message_
          if boolean (message_ .! "result" .! "error") then construct (global .! "Error") [message_ .! "result" .! "error"] >>= \error -> void $ call pending "reject" [error]
          else void $ call pending "resolve" [message_ .! "result"]

connect :: Value -> Effect Value
connect client
  | boolean (client .! "blocked") = call (global .! "Promise") "reject" [client .! "blocked"]
  | boolean (client .! "ready") = pure $ client .! "ready"
  | otherwise = do
      let generation = client .! "generation"
      call (global .! "crypto") "randomUUID" [] >>= set client "connectionId"
      ready <- promise \resolve reject -> do
        ws <- construct (global .! "WebSocket") [value $ T.replace "^http" "" "ws" (field "relay" $ client .! "session") <> "/api/socket"]
        set client "socket" ws
        timer <- delay 10000 do
          error <- construct (global .! "Error") [value unreachable]
          void $ invoke reject [error]
          void $ call ws "close" []
        delivery <- call (global .! "Promise") "resolve" []
        let local = value {delivery,queued:0}
        set ws "onopen" $ callback \_ -> call ws "send" [value $ stringify $ value {type:"auth",room:client .! "session" .! "room",token:client .! "session" .! "token"}]
        set ws "onmessage" $ callback \args -> do
          when (same (client .! "generation") generation) do
            outcome <- Exception.try do
              let raw = (at 0 args) .! "data"
              unless (kind raw == "string" && int (raw .! "length") <= 22008192) $ throw "Invalid relay response"
              data_ <- parseE $ string raw
              case field "type" data_ of
                "ready" -> cancelTimer timer *> void (invoke resolve [])
                "result" -> when (boolean $ data_ .! "error") do
                  error <- construct (global .! "Error") [data_ .! "error"]
                  rejectPending client error
                "messages" -> do
                  isArray <- call (global .! "Array") "isArray" [data_ .! "messages"]
                  setField local "queued" $ int (local .! "queued") + 1
                  unless (boolean isArray && A.length (items "messages" data_) <= 20 && int (local .! "queued") <= 2) $ throw "Relay overflow"
                  next <- call (local .! "delivery") "then" [callback \_ -> do
                    for_ (items "messages" data_) \item -> do
                      consume client item
                      setField client "serial" $ int (client .! "serial") + 1
                      void $ call ws "send" [value $ stringify $ value {type:"ack",id:field "serial" client,message:item .! "id"}]
                    pure null]
                  caught <- call next "catch" [callback \_ -> call ws "close" []]
                  last <- call caught "finally" [callback \_ -> setField local "queued" (int (local .! "queued") - 1) $> null]
                  set local "delivery" last
                _ -> pure unit
            case outcome of
              Left _ -> void $ call ws "close" []
              Right _ -> pure unit
          pure null
        set ws "onclose" $ callback \args -> do
          cancelTimer timer
          when (same (client .! "socket") ws) do
            set client "socket" null
            set client "ready" null
            let code = int $ (at 0 args) .! "code"
            error <- construct (global .! "Error") [value $ if code == 4001 then "Access revoked. Connect this corpora again." else if code == 4002 then "This connection is open in another window." else unreachable]
            setField error "revoked" $ code == 4001
            when (code == 4001 || code == 4002) $ set client "blocked" error
            when (code == 4001) $ clearSession $ client .! "session"
            void $ invoke reject [error]
            rejectPending client error
          pure null
        set ws "onerror" $ callback \_ -> call ws "close" []
      set client "ready" ready
      pure ready

requestRemote :: Value -> Value -> Int -> Aff Value
requestRemote client payload timeout = do
  void $ await $ connect client
  when (A.length (keys $ client .! "pending") >= 128) $ liftEffect $ throw "Connection busy. Try again shortly."
  let session = client .! "session"
      nacl = global .! "window" .! "RemoteVendor" .! "nacl"
  liftEffect do
    id <- call (global .! "crypto") "randomUUID" []
    nonce <- call nacl "randomBytes" [value 24]
    device <- call (global .! "window" .! "RemoteCode") "deviceInfo" []
    time <- now
    encoder <- construct (global .! "TextEncoder") []
    raw <- call encoder "encode" [value $ stringify $ merge [value {v:"sapiens-remote-box-v1",room:session .! "room",direction:"phone-to-desktop",corpora_id:session .! "corpora" .! "id",connection_id:client .! "connectionId",device_info:device,id,expires:time / 1000.0 + number (value timeout) / 1000.0},payload]]
    when (int (raw .! "length") > 16000000) $ throw "Request is too large."
    desktop <- bytes (field "desktop" session) 32
    ciphertext <- call nacl "box" [raw,nonce,desktop,session .! "keys" .! "secretKey"]
    let frame_ = value {sender:encode64 $ session .! "keys" .! "publicKey",nonce:encode64 nonce,ciphertext:encode64 ciphertext}
    promise \resolve reject -> do
      timer <- delay timeout do
        remove (client .! "pending") $ string id
        error <- construct (global .! "Error") [value unreachable]
        void $ invoke reject [error]
      setField (client .! "pending") (string id)
        {resolve:callback \args -> cancelTimer timer *> invoke resolve args, reject:callback \args -> cancelTimer timer *> invoke reject args}
      outcome <- Exception.try do
        setField client "serial" $ int (client .! "serial") + 1
        void $ call (client .! "socket") "send" [value $ stringify $ value {type:"send",id:field "serial" client,frame:frame_}]
      case outcome of
        Left error -> void (call (client .! "pending" .! string id) "reject" [value error]) *> remove (client .! "pending") (string id)
        Right _ -> pure unit
  >>= await <<< pure

create :: Value -> Effect Value
create session = do
  let keys_ = session .! "keys"
      nacl = global .! "window" .! "RemoteVendor" .! "nacl"
  valid <- if not (boolean keys_) || int (keys_ .! "secretKey" .! "length") /= 32 || int (keys_ .! "publicKey" .! "length") /= 32 then pure false
    else do
      pair <- call (nacl .! "box" .! "keyPair") "fromSecretKey" [keys_ .! "secretKey"]
      boolean <$> call nacl "verify" [pair .! "publicKey",keys_ .! "publicKey"]
  unless valid $ clearSession session *> throw "Saved device keys are invalid. Connect this corpora again."
  let client = value {session,socket:null,pending:value {},serial:0,generation:0}
  set client "connect" $ callback \_ -> connect client
  set client "consume" $ callback \args -> consume client (at 0 args) $> null
  set client "request" $ async \args -> requestRemote client (at 0 args) (int $ at 1 args <||> value 15000)
  set client "authenticate" $ async \args -> do
    let pair = boolean $ at 0 args
    result <- requestRemote client (if pair then value {kind:"pair",secret:session .! "secret"} else value {kind:"request",op:"resume"}) (if pair then 180000 else 15000)
    let corpora = result .! "corpora"
    unless (boolean (result .! "paired") && boolean corpora && kind (corpora .! "name") == "string" && int (corpora .! "name" .! "length") <= 200 && T.test "^([0-9a-f]{8}-)([0-9a-f]{4}-){3}[0-9a-f]{12}$" "" (field "id" corpora) && (not (boolean $ session .! "corpora") || same (corpora .! "id") (session .! "corpora" .! "id"))) $ liftEffect $ throw "Corpora identity changed. Connect again."
    liftEffect $ set session "corpora" corpora *> remove session "secret"
    void $ await $ call (global .! "window" .! "RemoteSession") "save" [session]
    pure corpora
  set client "fetch" $ async \args -> do
    let path = at 0 args
        options = at 1 args
        aborted = Lazy.defer \_ -> when (boolean $ options .! "signal" .! "aborted") do
          error <- liftEffect $ construct (global .! "DOMException") [value "Aborted",value "AbortError"]
          liftEffect $ Exception.throwException $ unsafeError error
    aborted
    data_ <- if boolean (options .! "body") then liftEffect $ parseE $ field "body" options else pure null
    result <- requestRemote client (merge [value {kind:"request",op:"api",method:options .! "method" <||> value "GET",path},if same data_ null then value {} else value {data:data_}]) 15000
    aborted
    integer <- liftEffect $ call (global .! "Number") "isInteger" [result .! "status"]
    unless (boolean integer) $ liftEffect $ throw "Invalid host response"
    liftEffect do
      body <- if boolean (result .! "binary") then bytes (field "body" result) 0 else pure $ value $ stringify $ result .! "body"
      construct (global .! "Response") [body,value {status:result .! "status",headers:value {"Content-Type":result .! "mime"}}]
  set client "close" $ callback \_ -> do
    setField client "generation" $ int (client .! "generation") + 1
    when (boolean $ client .! "socket") $ void $ call (client .! "socket") "close" []
    set client "socket" null
    set client "ready" null
    error <- construct (global .! "Error") [value "Connection closed"]
    rejectPending client error
    pure null
  pure client

foreign import unsafeError :: Value -> Exception.Error

invitation :: Value -> Aff Value
invitation data_ = do
  unless (boolean $ global .! "window" .! "isSecureContext") $ liftEffect $ throw "Open Sapiens4 over HTTPS."
  time <- liftEffect $ (_ / 1000.0) <$> now
  finite <- liftEffect $ call (global .! "Number") "isFinite" [data_ .! "expires"]
  unless (boolean data_ && field "v" data_ == "sapiens-remote-box-v1" && same (data_ .! "relay") (global .! "location" .! "origin") && boolean finite && number (data_ .! "expires") > time && number (data_ .! "expires") <= time + 259260.0 &&
    A.all (\key -> kind (data_ .! key) == "string" && T.test "^[A-Za-z0-9_-]{32,64}$" "" (field key data_)) ["room","token","secret"]) $ liftEffect $ throw "Invitation expired or belongs to another server. Use the latest QR from your host."
  void $ liftEffect $ bytes (field "desktop" data_) 32
  when (boolean $ data_ .! "public_id") do
    response <- await $ call global "fetch" [value $ "/api/corpora/" <> T.encode (field "public_id" data_),value {cache:"no-store",redirect:"error"}]
    found <- await $ call response "json" []
    latest <- liftEffect $ (_ / 1000.0) <$> now
    unless (boolean (response .! "ok") && same (found .! "desktop") (data_ .! "desktop") && number (found .! "expires") > latest) $ liftEffect $ throw "Invitation replaced. Use the latest QR from your host."
  liftEffect do
    keys_ <- call (global .! "window" .! "RemoteVendor" .! "nacl" .! "box") "keyPair" []
    create $ merge [data_,value {keys:keys_}]

main :: Effect Unit
main = do
  let constructor = constructible \args -> create $ at 0 args
  set constructor "bytes" $ callback \args -> bytes (string $ at 0 args) (int $ at 1 args)
  set constructor "b64" $ callback \args -> pure $ value $ encode64 $ at 0 args
  set constructor "invitation" $ async \args -> invitation $ at 0 args
  set (global .! "window") "RemoteTransport" constructor

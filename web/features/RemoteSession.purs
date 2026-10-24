module Sapiens.RemoteSession (main) where

import Prelude
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Function.Uncurried (mkFn1)
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff, makeAff, effectCanceler)
import Effect.Exception (Error, error, try)
import Effect.Ref as Ref
import Effect.Uncurried (mkEffectFn1)
import Foreign (Foreign)
import Sapiens.Async (Promise, toPromise)
import Sapiens.Browser as Browser

foreign import data Database :: Type
foreign import data Transaction :: Type
foreign import data Store :: Type
foreign import data Request :: Type -> Type
foreign import open :: String -> Int -> Effect (Request Database)
foreign import close :: Database -> Effect Unit
foreign import hasStore :: String -> Database -> Effect Boolean
foreign import createStore :: String -> Database -> Effect Unit
foreign import upgradeTransaction :: Request Database -> Effect Transaction
foreign import begin :: String -> String -> Database -> Effect Transaction
foreign import objectStore :: String -> Transaction -> Effect Store
foreign import result :: forall a. Request a -> Effect a
foreign import failure :: forall a. a -> Effect (Nullable Error)
foreign import handle :: forall a. String -> Effect Unit -> a -> Effect Unit
foreign import get :: forall a. String -> Store -> Effect (Request (Nullable a))
foreign import getAll :: Store -> Effect (Request (Array Session))
foreign import put :: forall a. a -> String -> Store -> Effect (Request String)
foreign import remove :: String -> Store -> Effect (Request Unit)
foreign import timer :: Int -> Effect Unit -> Effect (Effect Unit)
foreign import legacyIdentity :: Session -> Nullable String

type Session =
  { relay :: String, room :: String, token :: String, desktop :: String
  , keys :: Foreign, corpora :: { id :: String, name :: String } }

key :: Session -> String
key session = session.relay <> "|" <> session.corpora.id

transaction :: forall a. String -> (Store -> Effect (Request a)) -> Aff a
transaction mode operation = makeAff \complete -> do
  database <- Ref.new Nothing
  value <- Ref.new Nothing
  finished <- Ref.new false
  cancelTimer <- Ref.new (pure unit)
  let
    cleanup = do
      cancel <- Ref.read cancelTimer
      cancel
      db <- Ref.read database
      for_ db close
    finish status = do
      done <- Ref.read finished
      unless done do
        Ref.write true finished
        cleanup
        complete status
    failed problem = finish $ Left problem
    guard action = do
      outcome <- try action
      case outcome of
        Left problem -> failed problem
        Right _ -> pure unit
    requestError :: forall source. source -> Effect Unit
    requestError request = do
      problem <- failure request
      failed $ case toMaybe problem of
        Just actual -> actual
        Nothing -> error "Device storage failed."
  cancel <- timer 3000 (failed $ error "Device storage is unavailable.")
  Ref.write cancel cancelTimer
  guard do
    opening <- open "sapiens-remote" 2
    handle "onupgradeneeded" (guard do
      db <- result opening
      for_ ["device", "connections"] \name -> do
        exists <- hasStore name db
        unless exists $ createStore name db
      tx <- upgradeTransaction opening
      deviceStore <- objectStore "device" tx
      old <- get "trusted" deviceStore
      handle "onsuccess" (guard do
        saved <- result old
        for_ (toMaybe saved) \session -> for_ (toMaybe $ legacyIdentity session) \id ->
          when (id /= "") do
            store <- objectStore "connections" tx
            void $ put session (key session) store
        ) old
      ) opening
    handle "onerror" (requestError opening) opening
    handle "onblocked" (failed $ error "Close other Sapiens4 tabs and try again.") opening
    handle "onsuccess" (guard do
      db <- result opening
      done <- Ref.read finished
      if done then close db else do
        Ref.write (Just db) database
        tx <- begin "connections" mode db
        store <- objectStore "connections" tx
        request <- operation store
        handle "onsuccess" (result request >>= \observed -> Ref.write (Just observed) value) request
        handle "oncomplete" (do
          observed <- Ref.read value
          case observed of
            Just actual -> finish $ Right actual
            Nothing -> failed $ error "Device storage failed."
          ) tx
        handle "onabort" (requestError tx) tx
      ) opening
  pure $ effectCanceler do
    Ref.write true finished
    cleanup

list :: Effect (Promise (Array Session))
list = toPromise $ transaction "readonly" getAll

save :: Session -> Effect (Promise String)
save session = toPromise $ transaction "readwrite" \store ->
  put {version: 1, relay:session.relay, room:session.room, token:session.token,
    desktop:session.desktop, keys:session.keys, corpora:session.corpora} (key session) store

clear :: String -> Effect (Promise Unit)
clear id = toPromise $ transaction "readwrite" $ remove id

main :: Effect Unit
main = Browser.expose "RemoteSession" {key:mkFn1 key, list, save:mkEffectFn1 save, clear:mkEffectFn1 clear}

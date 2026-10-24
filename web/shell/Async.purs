module Sapiens.Async (Promise, fromPromise, toPromise) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, makeAff, nonCanceler, try)
import Effect.Class (liftEffect)
import Effect.Exception (Error)

foreign import data Promise :: Type -> Type
foreign import create :: forall a. ((a -> Effect Unit) -> (Error -> Effect Unit) -> Effect Unit) -> Effect (Promise a)
foreign import subscribe :: forall a. Promise a -> (a -> Effect Unit) -> (Error -> Effect Unit) -> Effect Unit

fromPromise :: forall a. Promise a -> Aff a
fromPromise promise = makeAff \complete -> do
  subscribe promise (complete <<< Right) (complete <<< Left)
  pure nonCanceler

toPromise :: forall a. Aff a -> Effect (Promise a)
toPromise action = create \resolve reject -> launchAff_ do
  result <- try action
  liftEffect $ case result of
    Right value -> resolve value
    Left error -> reject error

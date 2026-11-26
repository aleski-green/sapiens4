module Yoke (ReplayStep(..), cursorKey, planApply, readAfter, replayStep, shareable) where

import qualified Append4.KV as K
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as R
import Environment (EnvironmentId(..))

afterPrefix :: Text
afterPrefix = "?after="

devicePrefix :: Text
devicePrefix = "local/"

yokePrefix :: Text
yokePrefix = "yoke/"

cursorSuffix :: Text
cursorSuffix = "/after"

readAfter :: Text -> Maybe Integer
readAfter query = T.stripPrefix afterPrefix query >>= whole . R.decimal
 where
  whole (Right (number, rest)) = if T.null rest then Just number else Nothing
  whole (Left _) = Nothing

deviceOnly :: Text -> Bool
deviceOnly = T.isPrefixOf devicePrefix

shareable :: K.Append -> K.Append
shareable item = item { K.transactions = map shared (K.transactions item) }
 where
  shared tx = tx
   { K.mutations = filter (not . deviceOnly . K.keyOf) (K.mutations tx)
   , K.conditions = filter (not . deviceOnly . fst) (K.conditions tx) }

cursorKey :: EnvironmentId -> Text
cursorKey (EnvironmentId source) = devicePrefix <> yokePrefix <> source <> cursorSuffix

planApply :: EnvironmentId -> K.Append -> K.Transaction
planApply source@(EnvironmentId name) item = K.Transaction replayId [] (shared ++ [cursor])
 where
  replayId = yokePrefix <> name <> "/" <> T.pack (show (K.appendId item))
  shared = concatMap K.mutations (K.transactions (shareable item))
  cursor = K.Set (cursorKey source) (K.integerAtom (K.appendId item))

data ReplayStep = Replayed | ReplayRejected K.Outcome deriving (Eq, Show)

replayStep :: K.Outcome -> ReplayStep
replayStep outcome = case outcome of
 K.Accepted{} -> Replayed
 K.NoChange -> Replayed
 K.Conflict -> ReplayRejected outcome
 K.Duplicate -> ReplayRejected outcome
 K.Empty -> ReplayRejected outcome

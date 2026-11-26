module Yoke (readAfter, shareable) where

import qualified Append4.KV as K
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as R

afterPrefix :: Text
afterPrefix = "?after="

devicePrefix :: Text
devicePrefix = "local/"

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

module YokeWire (CatchUp(..), HistoryPage(..), Writer(..), decodePage, decodeWriter, encodeCatchUp) where

import qualified Append4.KV as K
import Data.Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import Environment (EnvironmentId(..))

data Writer = Writer Text (Maybe EnvironmentId)
instance FromJSON Writer where
 parseJSON = withObject "Corpora"
  (\o -> Writer <$> o .: "id" <*> (o .: "environment" >>= withObject "Environment" (.:? "id")))

data HistoryPage = HistoryPage { pageEnvironment :: EnvironmentId, pageAppends :: [K.Append] }
instance FromJSON HistoryPage where
 parseJSON = withObject "History page" (\o -> HistoryPage <$> o .: "environment" <*> o .: "appends")

data CatchUp = CatchUp { caughtSource :: EnvironmentId, caughtApplied :: Integer, caughtAfter :: Integer }
instance ToJSON CatchUp where
 toJSON c = object ["source" .= caughtSource c, "applied" .= caughtApplied c, "after" .= caughtAfter c]

decodeWriter :: BL.ByteString -> Either String Writer
decodeWriter = eitherDecode

decodePage :: BL.ByteString -> Either String HistoryPage
decodePage = eitherDecode

encodeCatchUp :: CatchUp -> BL.ByteString
encodeCatchUp = encode

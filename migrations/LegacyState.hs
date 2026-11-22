module LegacyState (migrateAgentState) where
import Types
import Control.Monad
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Aeson.Types (Parser)
migrateAgentState :: Int -> Value -> Validation AgentState
migrateAgentState version = validateValue 500 $ withObject "legacy agent state" $ \o -> do
 unless (version `elem` [1,2]) $ fail "Unsupported legacy state version"
 savedVersion <- o .: "schema_version"
 unless (savedVersion == version) $ fail "Mismatched legacy state version"
 agent <- o .: "agid" :: Parser Text
 revision <- o .: "revision" :: Parser Int
 sequenceNumber <- o .: "event_sequence" :: Parser Int
 lastOutput <- o .: "last_output" :: Parser (Maybe Text)
 history <- o .: (if version == 1 then "jobs" else "turns") >>= mapM migrateTurn
 chat <- o .: "chat" >>= mapM (message $ \row -> do
  void (row .: "role" :: Parser Text)
  void (row .: "content" :: Parser Text))
 events <- o .: "events" >>= mapM (message $ \row -> do
  void (row .: "sequence" :: Parser Int)
  void (row .: "kind" :: Parser Text))
 let buffered = if version == 2
       then KM.filterWithKey (\key _ -> key `elem` ["output_buffer","output_sequence"]) o
       else KM.empty
 pure $ AgentState (catMaybes history) (KM.fromList
  [("schema_version",num 3),("agid",str agent),("revision",num revision),("event_sequence",num sequenceNumber)
  ,("last_output",toJSON lastOutput),("chat",arr chat),("events",arr events)] <> buffered)
 where
 message validate = withObject "legacy message" $ \row -> do
  validate row
  void (row .:? "time" :: Parser (Maybe Text))
  void (row .:? "turn" :: Parser (Maybe Text))
  job <- traverse parseJSON (KM.lookup "job" row) :: Parser (Maybe Text)
  pure $ maybe (Object row) (\ident -> Object $ KM.insert "turn" (str ident) $ KM.delete "job" row) job
 migrateTurn = withObject "legacy turn" $ \row -> do
  ident <- row .: "id" :: Parser RunId
  input <- row .: (if version==1 then "task" else "input") :: Parser Text
  flow <- row .: "flow"
  status <- row .: "status" :: Parser Text
  let outputFields = ["origin","batch_id","batch_members","agency_kind","slot","pulseId","output_at","output_order"]
      extra = selectPresent (["created","error","warning"] ++ [key | version == 2, key <- outputFields]) (Object row)
      details = if status=="budget_blocked" then put "error" (str "Former budget block removed; retry to continue") extra else extra
  if version==1 && not (T.null flow) && flow `notElem` ["chat","computer"]
   then do -- v1 also stored jobs from configurable, retired flows.
    unless (status `elem` ["budget_blocked","conflict"]) $ void (parseJSON (str status) :: Parser TurnStatus)
    pure Nothing
   else do
    newStatus <- if status=="budget_blocked" then pure Interrupted else parseJSON (str status)
    Just <$> parseJSON (merge details (obj [("id",toJSON ident),("input",str input),("flow",str flow),("status",toJSON newStatus)]))

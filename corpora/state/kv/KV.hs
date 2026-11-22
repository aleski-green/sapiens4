{-# LANGUAGE ExistentialQuantification #-}
module KV
 ( Database, Ticket, submit, await, open, close, start, stop, runCommand, readSnapshot, pulse, getRecord, putRecord, deleteRecord
 , records, members, fieldsAt, afterCommit, currentPulse, history, atPulse, searchText, pendingCount, inTransaction, onCommit, onRollback, withActorContext
 ) where

import Crypto.Hash.SHA256 (hash)
import Data.ByteArray.Encoding (convertToBase, Base(Base16))
import qualified Data.Set as S
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Builder (toLazyByteString,word64BE)
import Data.IORef
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
import Data.Word
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.Vector as V
import System.FilePath
import System.IO (hPutStrLn,stderr)
import qualified LMDB
import qualified PulseClock

type Records = M.Map Text Value
newtype Ticket a = Ticket (MVar (Either SomeException a))

data Request = forall a. Request (IO a) (MVar (Either SomeException a))
data Database = Database
 { environment :: LMDB.Environment, diskLock :: MVar (), committed :: IORef Records
 , working :: IORef Records, sequenceNumber :: IORef Word64, owner :: IORef (Maybe ThreadId)
 , queue :: TBQueue Request, live :: IORef Bool, unregister :: MVar (Maybe (IO ()))
 , effects :: IORef [IO ()], receipts :: IORef [Value], transactionId :: IORef Text
 , touched :: IORef Bool, closed :: TVar Bool, actorName :: IORef Text, origins :: IORef (M.Map Text Value), rollbacks :: IORef [IO ()], reader :: IORef (Maybe ThreadId) }

open :: FilePath -> IO Database
open root = mask_ $ do
 env <- LMDB.open (root </> "state.lmdb")
 flip onException (LMDB.close env) $ do
  saved <- (++) <$> LMDB.prefix env "c/" <*> LMDB.prefix env "meta/"
  entries <- forM [(B.drop 2 k,v) | (k,v)<-saved,"c/" `B.isPrefixOf` k] $ \(k,v) ->
   (TE.decodeUtf8 k,) <$> either fail pure (eitherDecodeStrict' v)
  number <- case lookup "meta/pulse" saved of
   Nothing -> pure 0
   Just bytes -> either fail pure (eitherDecodeStrict' bytes)
  let state=M.fromList [(k,field "value" v) | (k,v)<-entries,field "present" v==Bool True]
  Database env <$> newMVar () <*> newIORef state <*> newIORef state <*> newIORef number
   <*> newIORef Nothing <*> newTBQueueIO 1024 <*> newIORef False <*> newMVar Nothing
   <*> newIORef [] <*> newIORef [] <*> newIORef "bootstrap" <*> newIORef False <*> newTVarIO False <*> newIORef "system" <*> newIORef M.empty <*> newIORef [] <*> newIORef Nothing

currentPulse :: Database -> IO Word64
currentPulse = readIORef . sequenceNumber
pendingCount :: Database -> IO Int
pendingCount db = fromIntegral <$> atomically (lengthTBQueue (queue db))
inTransaction :: Database -> IO Bool
inTransaction db = do
 thread <- myThreadId
 (==Just thread) <$> readIORef (owner db)
view :: Database -> IO Records
view db = do
 thread <- myThreadId
 reading <- (==Just thread) <$> readIORef (reader db)
 own <- inTransaction db
 active <- readIORef (live db)
 readIORef (if not reading && (own || not active) then working db else committed db)
getRecord :: Database -> Text -> IO (Maybe Value)
getRecord db key = M.lookup key <$> view db
records :: Database -> Text -> IO [(Text,Value)]
records db prefix = takeWhile (T.isPrefixOf prefix . fst) . M.toAscList . snd . M.split prefix <$> view db

assertWriter :: Database -> IO ()
assertWriter db = do
 thread <- myThreadId
 reading <- (==Just thread) <$> readIORef (reader db)
 when reading (fail "Domain write inside a committed read snapshot")
 own <- inTransaction db
 active <- readIORef (live db)
 when (active && not own) (fail "Domain write outside an atomic Pulse command")
putRecord :: Database -> Text -> Value -> IO ()
putRecord db key value = do
 assertWriter db
 when (T.any (=='\0') key || B.length (TE.encodeUtf8 key)>450) (fail "Storage key contains NUL or exceeds 450 bytes")
 tx <- readIORef (transactionId db)
 actor <- readIORef (actorName db)
 previous <- M.lookup key <$> readIORef (working db)
 let oldFields=flattenRecords (maybe M.empty (M.singleton key) previous)
     newFields=flattenRecords (M.singleton key value)
     changed=M.mergeWithKey (\_ a b -> if a==b then Nothing else Just ()) (M.map (const ())) (M.map (const ())) oldFields newFields
     origin=object ["actor" .= actor,"tx" .= tx]
 modifyIORef' (origins db) (\saved -> M.union (M.map (const origin) changed) saved)
 modifyIORef' (working db) (M.insert key value)
 writeIORef (touched db) True
deleteRecord :: Database -> Text -> IO ()
deleteRecord db key = putRecord db key Null >> modifyIORef' (working db) (M.delete key)

-- Every command is evaluated intact against the preceding accepted state.
-- Only the Pulse-wide before/after difference is netted; exceptions revert the
-- entire command. Successful callers are released only after the durable commit.
runCommand :: Database -> IO a -> IO a
runCommand db action = mask $ \restore -> do
 isClosed <- readTVarIO (closed db)
 when isClosed (fail "Store is closed")
 own <- inTransaction db
 active <- readIORef (live db)
 if own then atomicCommand db action >>= either throwIO pure else if not active then restore action else do
  ticket <- submit db action
  restore (await ticket)

-- Reads pin one committed view for their entire action. They cannot observe a
-- tentative command state that a later command in the same Pulse nets away.
readSnapshot :: Database -> IO a -> IO a
readSnapshot db action = do
 own <- inTransaction db
 if own then action else withReadLock db $ do
  thread <- myThreadId
  bracket (atomicModifyIORef' (reader db) (Just thread,))
   (writeIORef (reader db)) (const action)

withReadLock :: Database -> IO a -> IO a
withReadLock db action = do
 own <- inTransaction db
 thread <- myThreadId
 reading <- (==Just thread) <$> readIORef (reader db)
 if reading || own then action else withMVar (diskLock db) $ \_ -> do
  isClosed <- readTVarIO (closed db)
  when isClosed (fail "Store is closed")
  action

submit :: Database -> IO a -> IO (Ticket a)
submit db action = do
 isClosed <- readTVarIO (closed db)
 when isClosed (fail "Store is closed")
 reply <- newEmptyMVar
 accepted <- atomically $ do
  isClosed <- readTVar (closed db)
  when isClosed (throwSTM (userError "Store is closed"))
  full <- isFullTBQueue (queue db)
  if full then pure False else writeTBQueue (queue db) (Request action reply) >> pure True
 unless accepted (fail "Pulse mempool is full; retry later")
 pure (Ticket reply)
await :: Ticket a -> IO a
await (Ticket reply) = readMVar reply >>= either throwIO pure

atomicCommand :: Database -> IO a -> IO (Either SomeException a)
atomicCommand db action = mask $ \restore -> do
 before <- readIORef (working db)
 pendingEffects <- readIORef (effects db)
 oldReceipts <- readIORef (receipts db)
 oldTouched <- readIORef (touched db)
 oldRollbacks <- readIORef (rollbacks db)
 oldOrigins <- readIORef (origins db)
 previousId <- readIORef (transactionId db)
 identity <- UUID.toText <$> UUID.nextRandom
 writeIORef (transactionId db) identity
 writeIORef (touched db) False
 result <- try (restore action)
 changed <- readIORef (touched db)
 case result of
  Left _ -> do
   undo <- readIORef (rollbacks db)
   sequence_ (reverse (drop (length oldRollbacks) undo))
   writeIORef (rollbacks db) oldRollbacks
   writeIORef (working db) before
   writeIORef (origins db) oldOrigins
   writeIORef (effects db) pendingEffects
   writeIORef (receipts db) oldReceipts
  Right _ -> when changed $ modifyIORef' (receipts db)
   (++[object ["id" .= identity,"outcome" .= ("committed"::Text)]])
 writeIORef (transactionId db) previousId
 writeIORef (touched db) oldTouched
 pure result

withActorContext :: Database -> Text -> IO a -> IO a
withActorContext db actor action = bracket (atomicModifyIORef' (actorName db) (actor,))
 (writeIORef (actorName db)) (const action)
onRollback :: Database -> IO () -> IO ()
onRollback db undo = assertWriter db >> modifyIORef' (rollbacks db) (++[undo])
onCommit :: Database -> IO () -> IO ()
onCommit db action = assertWriter db >> modifyIORef' (effects db) (++[action])

afterCommit :: Database -> Text -> Value -> IO () -> IO ()
afterCommit db identity payload action = do
 putRecord db ("intents/"<>identity) (object ["status" .= ("pending"::Text),"input" .= payload])
 modifyIORef' (effects db) (++[action])

start :: Database -> IO () -> IO ()
start db scheduled = modifyMVar_ (unregister db) $ \existing -> case existing of
 Just _ -> pure existing
 Nothing -> do
  -- Bootstrap is committed before clients can see this root.
  pulse db (pure ())
  writeIORef (live db) True
  Just <$> PulseClock.register (pulse db scheduled)
stop :: Database -> IO ()
stop db = do
 modifyMVar_ (unregister db) $ \callback -> sequence_ callback >> pure Nothing
 -- Stop admission before this call. Final pending commands use the same commit path.
 pulse db (pure ())
 writeIORef (live db) False
close :: Database -> IO ()
close db = mask_ $ do
 wasClosed <- atomically $ do old <- readTVar (closed db); writeTVar (closed db) True; pure old
 unless wasClosed $ do
  modifyMVar_ (unregister db) $ \callback -> sequence_ callback >> pure Nothing
  withMVar (diskLock db) $ \_ -> do
   pending <- atomically $ let drain = tryReadTBQueue (queue db) >>= maybe (pure []) (\r -> (r:) <$> drain) in drain
   forM_ pending $ \(Request _ reply) -> putMVar reply (Left (toException (userError "Store closed before commit")))
   LMDB.close (environment db)

pulse :: Database -> IO () -> IO ()
pulse db scheduled = mask $ \restore -> do
 deliveries <- withMVar (diskLock db) $ \_ -> do
  isClosed <- readTVarIO (closed db)
  if isClosed then pure [] else do
   thread <- myThreadId
   bracket_ (writeIORef (owner db) (Just thread)) (writeIORef (owner db) Nothing) $ do
    pending <- atomically $ let drain = tryReadTBQueue (queue db) >>= maybe (pure []) (\r -> (r:) <$> drain) in drain
    outcomes <- forM pending $ \(Request action reply) -> do
     result <- atomicCommand db action
     pure (\problem -> putMVar reply (maybe result Left problem))
    scheduledResult <- atomicCommand db scheduled
    previous <- readIORef (committed db)
    result <- try (persist db)
    case result of
     Left problem -> do
      undo <- atomicModifyIORef' (rollbacks db) ([],)
      sequence_ (reverse undo)
      writeIORef (origins db) M.empty
      writeIORef (working db) previous
      writeIORef (effects db) []
      writeIORef (receipts db) []
      pure (map ($ Just problem) outcomes ++ [throwIO (problem::SomeException)])
     Right () -> do
      writeIORef (rollbacks db) []
      callbacks <- atomicModifyIORef' (effects db) ([],)
      pure (map ($ Nothing) outcomes ++ map runEffect callbacks ++ either (\e -> [throwIO e]) (const []) scheduledResult)
 sequence_ (map restore deliveries)
 where
 runEffect action = action `catch` \(problem::SomeException) ->
  case fromException problem :: Maybe SomeAsyncException of
   Just _ -> throwIO problem
   Nothing -> hPutStrLn stderr ("Committed effect could not start: "++displayException problem)

-- Current records are disposable projections. Authoritative field facts, commit
-- records and receipts use MDB_NOOVERWRITE. All are written in ONE LMDB txn.
persist :: Database -> IO ()
persist db = do
 before <- readIORef (committed db)
 after <- readIORef (working db)
 oldPulse <- currentPulse db
 when (oldPulse == maxBound) (fail "Pulse sequence exhausted")
 let next=oldPulse+1
     changed=M.mergeWithKey (\_ a b -> if a==b then Nothing else Just (Just b)) (M.map (const Nothing)) (M.map Just) before after
     changedKeys=M.keysSet changed
     oldFields=flattenRecords (M.restrictKeys before changedKeys)
     newFields=flattenRecords (M.restrictKeys after changedKeys)
     delta=M.mergeWithKey (\_ a b -> if a==b then Nothing else Just (Just b)) (M.map (const Nothing)) (M.map Just) oldFields newFields
 timestamp <- getCurrentTime
 sources <- readIORef (origins db)
 txs <- readIORef (receipts db)
 let encodeBytes :: ToJSON a => a -> B.ByteString
     encodeBytes=L.toStrict . encode
     originFor key = M.lookup key sources
     facts=[("h/"<>TE.encodeUtf8 key<>B.singleton 0<>pulseBytes next,encodeBytes (object ["key" .= key,"pulse" .= next,"value" .= value,"source" .= originFor key,"timestamp" .= timestamp]),True) | (key,value)<-M.toAscList delta]
     postings=[("t/"<>trigramKey gram<>"/"<>hash (TE.encodeUtf8 key)<>pulseBytes next,encodeBytes (object ["key" .= key,"pulse" .= next]),True)
              | (key,Just atom)<-M.toAscList delta, String txt<-[field "data" atom],gram<-trigrams txt]
     projections=[("c/"<>TE.encodeUtf8 key,encodeBytes (object ["present" .= isJust value,"value" .= value]),False) | (key,value)<-M.toAscList changed]
     memberships=[("i/"<>TE.encodeUtf8 key<>B.singleton 0<>pulseBytes next,encodeBytes (object ["key" .= key,"pulse" .= next,"present" .= M.member key after]),True)
                 | key<-M.keys changed,M.member key before /= M.member key after]
     commitRow=("p/"<>pulseBytes next,encodeBytes (object ["pulse" .= next,"timestamp" .= timestamp,"transactions" .= txs]),True)
 forM_ facts $ \(key,_,_) -> when (B.length key>511) (fail "Field path exceeds LMDB key limit")
 LMDB.commit (environment db) (facts++postings++memberships++projections++[commitRow,("meta/pulse",encodeBytes next,False)])
 writeIORef (sequenceNumber db) next
 writeIORef (committed db) after
 writeIORef (receipts db) []
 writeIORef (origins db) M.empty

pulseBytes :: Word64 -> B.ByteString
pulseBytes = L.toStrict . toLazyByteString . word64BE
-- JSON is an application boundary. Facts store a primitive per leaf; container
-- markers retain empty objects, empty arrays and exact array order.
flattenRecords :: Records -> M.Map Text Value
flattenRecords = M.fromList . concatMap (uncurry flatten) . M.toAscList
 where
 escape = T.replace "\0" "~2" . T.replace "/" "~1" . T.replace "~" "~0"
 flatten key value = case value of
  Object fields -> (key,object ["type" .= ("object"::Text)]) : concat [flatten (key<>"/"<>escape (K.toText k)) v | (k,v)<-KM.toList fields]
  Array values -> (key,object ["type" .= ("array"::Text),"length" .= V.length values]) : concat [flatten (key<>"/"<>T.pack (show i)) v | (i,v)<-zip [0::Int ..] (V.toList values)]
  _ -> [(key,object ["type" .= ("primitive"::Text),"data" .= value])]

history :: Database -> Text -> IO [Value]
history db key = withReadLock db (historyUnlocked db key)
historyUnlocked :: Database -> Text -> IO [Value]
historyUnlocked db key = do
 saved <- LMDB.prefix (environment db) ("h/"<>TE.encodeUtf8 key<>B.singleton 0)
 traverse (either fail pure . eitherDecodeStrict' . snd) saved
atPulse :: Database -> Word64 -> Text -> IO (Maybe Value)
atPulse db number key = do
 versions <- history db key
 pure (latestAt number versions >>= \v -> case field "value" v of Null -> Nothing; atom -> Just atom)
latestAt :: Word64 -> [Value] -> Maybe Value
latestAt number = listToMaybe . reverse . filter (\v -> case field "pulse" v of Number p -> p<=fromIntegral number; _ -> False)
field :: K.Key -> Value -> Value
field name (Object o)=fromMaybe Null (KM.lookup name o)
field _ _=Null
trigrams :: Text -> [Text]
trigrams = S.toList . S.fromList . map (T.take 3) . filter ((>=3) . T.length) . T.tails
trigramKey :: Text -> B.ByteString
trigramKey = convertToBase Base16 . TE.encodeUtf8
searchText :: Database -> Bool -> Text -> IO [Value]
searchText db historical query = withReadLock db $ do
 versions <- case trigrams query of
  [] -> LMDB.prefix (environment db) "h/" >>= traverse (either fail pure . eitherDecodeStrict' . snd)
  grams -> do
   sets <- forM grams $ \gram -> do
    postings <- LMDB.prefix (environment db) ("t/"<>trigramKey gram<>"/")
    refs <- traverse (either fail pure . eitherDecodeStrict' . snd) postings
    pure (S.fromList [(key,pulse) | ref<-refs,String key<-[field "key" ref],Number pulse<-[field "pulse" ref]])
   let candidates=case sets of [] -> S.empty; first:rest -> foldl S.intersection first rest
   fmap catMaybes $ forM (S.toList candidates) $ \(key,number) -> do
    facts <- historyUnlocked db key
    pure (listToMaybe [v | v<-facts,field "pulse" v==Number number])
 let matches v=case field "data" (field "value" v) of String t -> query `T.isInfixOf` t; _ -> False
 number <- currentPulse db
 filterM (\v -> if not (matches v) then pure False else if historical then pure True else case field "key" v of
  String key -> (==Just v) . latestAt number <$> historyUnlocked db key
  _ -> pure False) versions

-- Membership is itself versioned: deleting a current entity cannot erase its
-- historical collection position. Prefixes are application collection scopes.
members :: Database -> Maybe Word64 -> Text -> IO [Text]
members db Nothing prefix = map fst <$> records db prefix
members db (Just number) prefix = withReadLock db $ do
 saved <- LMDB.prefix (environment db) ("i/"<>TE.encodeUtf8 prefix)
 versions <- traverse (either fail pure . eitherDecodeStrict' . snd) saved
 pure [key | (key,rows)<-M.toAscList (groupVersions versions),Just row<-[latestAt number rows],field "present" row==Bool True]

-- Resolve primitive fields and container markers from one immutable read view.
fieldsAt :: Database -> Word64 -> Text -> IO [(Text,Value)]
fieldsAt db number prefix = withReadLock db $ do
 saved <- LMDB.prefix (environment db) ("h/"<>TE.encodeUtf8 prefix)
 versions <- traverse (either fail pure . eitherDecodeStrict' . snd) saved
 pure [(key,atom) | (key,rows)<-M.toAscList (groupVersions versions),Just row<-[latestAt number rows],let atom=field "value" row,atom/=Null]

groupVersions :: [Value] -> M.Map Text [Value]
groupVersions = M.fromListWith (flip (++)) . mapMaybe (\row -> case field "key" row of String key -> Just (key,[row]); _ -> Nothing)

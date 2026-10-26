{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Sapiens.Execution where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.List (find,nub)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock
import System.Directory
import System.FilePath
import Sapiens.Types
import qualified Sapiens.Store as DB
import Sapiens.Population
import Sapiens.Workspace
import qualified Sapiens.Delegation as D
import qualified Sapiens.Routines as R
import Sapiens.Provider
import qualified Sapiens.GroupChat as G

trimConversation :: Service -> Text -> IO ()
trimConversation s a = do
 state <- agentState s a
 bounded <- foldM (\current field -> do
  let rows=items current field
      settled=filter (\row -> at row "status" `notElem` ["queued","running","output_pending"]) rows
      removed=take (max 0 (length settled-100)) settled
  unless (null removed) $ newId >>= \i -> writeJSON (archivePath s a (field<>"/"<>i)) (arr removed)
  pure (put field (arr (filter (`notElem` removed) rows)) current)) state ["chat","events","turns"]
 final <- foldM (\current field -> do
  let prune value removed [] = pure (value,removed)
      prune value removed (row:rest)
       | BL.length (encode value)<=800000 = pure (value,removed)
       | at row "status" `elem` ["queued","running","output_pending"] || (field=="turns" && Just row==listToMaybe (reverse (items value field))) = prune value removed rest
       | otherwise = prune (put field (arr (filter (/=row) (items value field))) value) (removed++[row]) rest
  (result,removed) <- prune current [] (items current field)
  unless (null removed) $ newId >>= \i -> writeJSON (archivePath s a (field<>"/"<>i)) (arr removed)
  pure result) bounded ["chat","events","turns"]
 when (final/=state) (saveState s a final)
submitTurn :: Service -> Text -> Value -> IO Value
submitTurn s a d = do
 let raw=get d "text" `fallback` str ""; input=T.strip (text raw); flow=get d "flow" `fallback` str "chat"
 require (case raw of String t -> T.length t<=16000; _ -> False) 400 "Message must be text, at most 16000 characters"
 attachments <- resolveAttachments s a (get d "attachments" `fallback` arr []) True
 require (not (T.null input) || not (null attachments)) 400 "Write a message or attach a file"
 require (flow `elem` map str ["chat","computer"]) 400 "Choose chat or computer"
 binary <- codexBinary
 require (isJust binary) 503 "Codex CLI is missing. Install it and run codex login."
 when (flow==str "computer") $ blindly s >>= doesFileExist >>= \built -> require built 503 "Blindly4 is not built. Run ./start.sh to build it."
 stopped <- readIORef (serviceStopping s)
 require (not stopped) 503 "Server is shutting down"
 requireActive s a
 routine <- R.command s a input (not (null attachments))
 case routine of
  Just r -> R.acknowledge s a input r
  Nothing -> do
   suffix <- attachmentPrompt s attachments
   let message=input<>suffix
   i <- if has d "workload" then D.clarify s a (at d "workload") message else do
    i <- newId
    time <- now
    let turn=obj [("id",str i),("flow",flow),("input",str message),("status",str "queued"),("created",str time),("attempt",num 1),("origin",Null),("batchable",Bool True)]
        msg=obj [("role",str "user"),("content",str message),("turn",str i),("time",str time),("origin",Null)]
    modifyState s a $ \state -> merge state (obj [("turns",arr (items state "turns"++[turn])),("chat",arr (items state "chat"++[msg]))])
    pure i
   DB.message s i input attachments
   DB.project s a
   trimConversation s a
   pure (obj [("id",str i),("agent",str a),("status",str "queued"),("flow",flow)])
turnAction :: Service -> Text -> Text -> Text -> IO Value
turnAction s a identity action = do
 requireActive s a
 state <- agentState s a
 turn <- maybe (failure 404 "Unknown active turn") pure (findId identity (items state "turns"))
 work <- D.findWork s identity
 require (not (maybe False (any ((==str identity) . (`get` "causedBy")) . (`items` "calls") . fst) work)) 409 "This request was delegated; use the recipient call controls"
 let leader=text (get turn "batch_id" `fallback` get turn "id")
     member t = text (get t "batch_id" `fallback` get t "id") == leader
 case action of
  "retry" -> do
   require (at turn "status" `elem` ["failed","interrupted"]) 409 "Only failed or interrupted batches can be retried"
   saveState s a $ mapTurns (\t -> if member t then merge (remove ["error","batch_id","batch_members","agency_kind","slot","pulseId"] t) (obj [("status",str "queued"),("attempt",num (int (get t "attempt")+1))]) else t) state
  "cancel" -> do
   require (at turn "status" `notElem` ["done","output_pending"]) 409 "Completed input cannot be cancelled"
   runs <- readMVar (serviceRuns s)
   case M.lookup leader runs of
    Just run -> writeIORef (runCancel run) True
    Nothing -> saveState s a (mapTurns (\t -> if member t then put "status" (str "cancelled") t else t) state)
  _ -> failure 404 "Unknown turn action"
 DB.project s a
 trimConversation s a
 D.reconcileWorks s
 updated <- agentState s a
 pure (obj [("id",str identity),("status",maybe Null (`get` "status") (findId identity (items updated "turns")))])
recover :: Service -> Text -> IO ()
recover s a = do
 modifyState s a $ mapTurns (\t -> if at t "status"=="running" then merge t (obj [("status",str "interrupted"),("error",str "Runner stopped before saving a reply; inspect effects before retrying")]) else t)
 DB.project s a
finish :: Service -> Run -> Value -> Either SomeException (Text,[Value]) -> IO ()
finish s run turn outcome = do
 stop <- readIORef (runCancel run)
 let a=runOwner run; i=runId run
     (output,logs,error)=case outcome of
      Left e -> case fromException e of
       Just (RunFailure message entries)->("",entries,Just message)
       Nothing->("",[],Just (D.exceptionText e))
      Right (value,entries)->(value,entries,Nothing)
     failureText=if stop then Just "Stopped by Admin. Saved work is preserved; review external effects before retrying." else error
 writeJSON (archivePath s a ("runs/"<>i)) (obj [("output",str output),("logs",arr logs),("error",maybe Null str failureText)])
 state <- agentState s a
 time <- now
 let ids=if has turn "batch_members" then items turn "batch_members" else [str i]
     update t | get t "id" `notElem` ids = t
              | Just e <- failureText = merge t (obj [("status",str (if stop then "interrupted" else "failed")),("error",str e)])
              | at turn "agency_kind"=="chatInput" = put "status" (str "output_pending") t
              | otherwise = merge t (obj [("status",str "done"),("output_at",str time)])
     warnings=[at entry "warning" | entry<-logs,has entry "warning"]
     updated=mapTurns (\t -> let result=update t in if get t "id" `elem` ids then if null warnings then remove ["warning"] result else put "warning" (str (T.intercalate " " warnings)) result else result) state
     result | isJust failureText = updated
            | at turn "agency_kind"=="chatInput" = put "output_buffer" (arr (items state "output_buffer"++[obj [("turn",str i),("members",arr ids),("content",str output),("origin",get turn "origin")]])) updated
            | has (get turn "origin") "group" = updated
            | otherwise = merge updated (obj [("chat",arr (items state "chat"++[obj [("role",str "agent"),("content",str output),("turn",str i),("time",str time),("origin",get turn "origin")]])),("last_output",str output)])
 saveState s a result
 DB.project s a
 trimConversation s a
 D.reconcileWorks s
launch :: Service -> Text -> [Value] -> Value -> Int -> Bool -> IO ()
launch s a batch tick slot batching = do
 state <- agentState s a
 let first=head batch; i=at first "id"; ids=map (`get` "id") batch
     reserve t = if get t "id" `elem` ids then merge (remove ["error"] t) (obj ([("status",str "running")] ++ (if batching then [("batch_id",str i),("agency_kind",str "chatInput"),("slot",num slot),("pulseId",get tick "pulseId")] else []))) else t
     reserved=mapTurns reserve state
     marked=if batching then mapTurns (\t -> if at t "id"==i then put "batch_members" (arr ids) t else t) reserved else reserved
     snapshot=merge marked (obj ([("current_turn",str i)] ++ [("agency_batch",arr [obj [("id",get t "id"),("content",get t "input")] | t <- batch]) | batching]))
     execution=put "input" (str (T.intercalate "\n\n" (map (`at` "input") batch))) (fromJust (findId i (items marked "turns")))
 saveState s a marked
 cancel <- newIORef False
 process <- newMVar Nothing
 activity <- newIORef empty
 deadline <- (+1800000000000) <$> getMonotonicTimeNSec
 let run=Run a i slot cancel process activity deadline
 modifyMVar_ (serviceRuns s) (pure . M.insert i run)
 DB.pulseCall s tick a "chatInput" slot (nub [at (get t "origin") "group" | t <- batch,has (get t "origin") "group"])
 DB.project s a
 void $ forkIO $ do
  result <- try (withActor s a (Just "chatInput") (if has (get execution "origin") "group" then G.runGroup s run execution snapshot else D.runDecision s run execution snapshot))
  locked s $ finish s run execution result `finally` do
   lease <- readIORef (serviceLease s)
   when (lease==Just (a,i)) $ writeIORef (serviceLease s) Nothing
   modifyMVar_ (serviceRuns s) (pure . M.delete i)
   D.pendingWorks s
   G.reconcileGroups s
   G.dispatchGroups s
publish :: Service -> Text -> Value -> IO ()
publish s a tick = forM_ [1,2] $ \slot -> do
 state <- agentState s a
 let scheduled=at tick "frequency"=="bph60"
     eligible item=has (get item "origin") "routine" == scheduled
 case find eligible (items state "output_buffer") of
  Nothing -> pure ()
  Just item -> do
   time <- now
   let sequence=int (get state "output_sequence")+1
       ids=items item "members"; origin=get item "origin"
       updated=mapTurns (\t -> if get t "id" `elem` ids then merge t (obj [("status",str "done"),("output_at",str time),("output_order",num sequence)]) else t) state
       messages=if has origin "group" || any (\m -> get m "turn"==get item "turn" && at m "role"=="agent") (items state "chat") then items state "chat" else items state "chat"++[obj [("role",str "agent"),("content",get item "content"),("turn",get item "turn"),("time",str time),("origin",origin)]]
   saveState s a $ merge updated (obj ([("output_buffer",arr (filter (/=item) (items state "output_buffer"))),("output_sequence",num sequence),("chat",arr messages)] ++ [("last_output",get item "content") | not (has origin "group")]))
   DB.pulseCall s tick a "chatOutput" slot [at origin "group" | has origin "group"]
   DB.project s a
   trimConversation s a
admit :: Service -> Text -> Value -> IO ()
admit s a tick = do
 runs <- readMVar (serviceRuns s)
 state <- agentState s a
 let owners=nub (map runOwner (M.elems runs)); mine=filter ((==a) . runOwner) (M.elems runs); available=[n | n<-[1,2],n `notElem` map runSlot mine]
     scheduled=at tick "frequency"=="bph60"
     queued=[t | t<-items state "turns",at t "status"=="queued",boolean (get t "batchable"),has (get t "origin") "routine"==scheduled]
     legacy=[t | t<-items state "turns",at t "status"=="queued",not (boolean (get t "batchable"))]
 when (a `elem` owners || length owners<4) $ if not (null legacy) && null mine && not scheduled then launch s a [head legacy] tick 0 False else when (not (null available) && not (null queued) && all ((/=0) . runSlot) mine) $ launch s a (if scheduled then take 1 queued else queued) tick (head available) True
onPulse :: Service -> Value -> IO ()
onPulse s tick = do
 R.dispatch s tick
 when (at tick "frequency"=="bph60" || (at tick "frequency"=="bpm60" && even (int (get tick "num")))) $ do
  D.pendingWorks s
  G.reconcileGroups s
  G.dispatchGroups s
  rows <- DB.agents s
  forM_ rows $ \row -> do
   let a=at row "id"
   inactive <- retired s a
   unless inactive $ do
    publish s a tick
    admit s a tick
    when (at tick "frequency"=="bph60") $ admit s a tick
milliseconds :: IO Int
milliseconds = fromIntegral . (`div` 1000000) <$> getMonotonicTimeNSec
startExecution :: Service -> IO ()
startExecution s = modifyMVar_ (serviceWorker s) $ \existing -> case existing of
 Just _ -> pure existing
 Nothing -> Just <$> async loop
 where
 loop = do
  t <- milliseconds
  deadlines <- newIORef (M.fromList [("bpm120",t+500),("bpm60",t+1000),("bph60",t+60000)])
  let step = do
       stopped <- readIORef (serviceStopping s)
       unless stopped $ do
        locked s $ do
         config <- corporaSettings s
         pulse <- readIORef (servicePulse s)
         let active=at config "status"=="active"
         writeIORef (servicePulse s) (put "running" (Bool active) pulse)
         time <- milliseconds
         if not active then writeIORef deadlines (M.fromList [("bpm120",time+500),("bpm60",time+1000),("bph60",time+60000)]) else forM_ [("bpm120",500),("bpm60",1000),("bph60",60000)] $ \(frequency,interval) -> do
          due <- fromMaybe time . M.lookup frequency <$> readIORef deadlines
          when (time>=due) $ do
           let elapsed=(time-due) `div` interval+1
           modifyIORef' deadlines (M.insert frequency (due+elapsed*interval))
           current <- readIORef (servicePulse s)
           let number=int (get (get current "numbers") frequency)+elapsed; numbers=put frequency (num number) (get current "numbers"); identity=at current "id"
           writeIORef (servicePulse s) (put "numbers" numbers current)
           DB.saveSingleton s "system_pulse" (obj [("pulse",str identity),("numbers",numbers)])
           onPulse s (obj [("pulse",str identity),("frequency",str frequency),("num",num number),("pulseId",str (identity<>":"<>frequency<>":"<>T.pack (show number)))])
        threadDelay 50000
        step
  step
stopRuns :: Service -> IO ()
stopRuns s = readMVar (serviceRuns s) >>= mapM_ (\run -> writeIORef (runCancel run) True) . M.elems

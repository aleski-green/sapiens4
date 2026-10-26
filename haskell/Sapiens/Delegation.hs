{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Sapiens.Delegation where

import Control.Concurrent
import qualified Data.Map.Strict as M
import Control.Exception
import Control.Monad
import Crypto.Hash.SHA256 (hash)
import Data.Aeson hiding (pairs)
import qualified Data.ByteString as BS
import Data.IORef
import Data.List (find,nub,sort)
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Numeric (showHex)
import System.Directory
import System.FilePath
import Sapiens.Types
import qualified Sapiens.Store as DB
import Sapiens.Population
import Sapiens.Memo
import Sapiens.Provider

promptNames :: [(Text,Text)]
promptNames = [("Assessing","decision-triage"),("ChiefTriage","decision-chief-triage"),("CreatingSapi","decision-create-sapi"),("ReadyToWork","decision-prepare-task"),("Delegation","decision-delegation"),("Execution","decision-execution")]
eventsFor :: Text -> [Text]
eventsFor node = fromMaybe [] $ lookup node [("Assessing",["FitsSpecialization","OutsideSpecialization"]),("ChiefTriage",["FitsSpecialization","SpecialistSelected","NewSpecialistNeeded","RequestUnclear"]),("CreatingSapi",["SapiSpecified"]),("ReadyToWork",["TaskPrepared"]),("Delegation",["HandoffPrepared"]),("Execution",["Outcome","OutsideSpecialization"])]
fieldsFor :: Text -> [Text]
fieldsFor event = fromMaybe [] (lookup event [("FitsSpecialization",["mode","reply"]),("SpecialistSelected",["target"]),("RequestUnclear",["question"]),("SapiSpecified",["name","role"]),("TaskPrepared",["taskType","specification"]),("HandoffPrepared",["request"]),("Outcome",["reply","outcome"])])
templates :: Service -> IO [Value]
templates s = forM promptNames $ \(node,name) -> do
 let local = serviceRoot s </> "decision-prompts" </> T.unpack name <.> "md"
 exists <- doesFileExist local
 let p = if exists then local else repositoryRoot s </> "prompts" </> T.unpack name <.> "md"
 content <- readText p
 pure $ obj [("node",str node),("template",str (name<>".md")),("path",str (T.pack p)),("content",str content)]
editTemplate :: Service -> Text -> Value -> IO Value
editTemplate s node d = do
 name <- maybe (failure 400 "Unknown decision node or field") pure (lookup node promptNames)
 require (keys d == ["content"]) 400 "Unknown decision node or field"
 content <- textField d "content" 20000
 let p = serviceRoot s </> "decision-prompts" </> T.unpack name <.> "md"
 writeText p content
 pure (obj [("saved",Bool True),("path",str (T.pack p))])
findWork :: Service -> Text -> IO (Maybe (Value,Value))
findWork s i = do
 works <- DB.values s "workloads"
 pure $ listToMaybe [(w,c) | w <- works,c <- items w "calls",at c "callId" == i]
getWork :: Service -> Text -> IO (Value,Value)
getWork s i = findWork s i >>= maybe (failure 409 "Unknown workload call") pure
saveWork :: Service -> Value -> IO ()
saveWork s w = do
 previous <- find ((==at w "workloadId") . (`at` "workloadId")) <$> DB.values s "workloads"
 let call=last (items w "calls")
     before=maybe empty (fromMaybe empty . listToMaybe . reverse . (`items` "calls")) previous
     changed=maybe False (\old -> boolean (get w "tracked") && (not (boolean (get old "tracked")) || (get call "state",get call "addressedTo")/=(get before "state",get before "addressedTo"))) previous
 when changed $ do
  (source,agency) <- currentActor s
  let state=at call "state"
      actor=if isJust agency || state=="Cancelled" then source else if state=="Queued" then "system" else at call "addressedTo"
      detail=obj [("owner",get call "addressedTo"),("task",get w "task"),("previous",get before "state"),("call",get call "callId"),("error",get call "error")]
  DB.record s (map (`at` "addressedTo") (items w "calls")) (at (get w "task") "taskId") ("task."<>T.toLower state) detail actor (if state `elem` ["Queued","Cancelled"] then Nothing else Just "chatInput")
 DB.putValue s "workloads" (at w "workloadId") w
withCall :: Value -> Value -> Value
withCall w c = put "calls" (arr [if get x "callId" == get c "callId" then c else x | x <- items w "calls"]) w
strings :: Value -> Text -> Bool -> IO ()
strings value name nonempty = require (case value of Array _ -> length (list value) <= 50 && (not nonempty || not (null (list value))) && all valid (list value); _ -> False) 400 (name <> " must be a list of nonempty strings")
 where valid (String t) = not (T.null (T.strip t)) && T.length t <= 16000; valid _ = False
validateOutcome :: Value -> [Value] -> IO Value
validateOutcome response criteria = do
 let outcome = get response "outcome"; required=["status","satisfiedCriteria","artifacts"]; skipped=get outcome "notApplicableCriteria" `fallback` empty
 require (all (has outcome) required && all (`elem` (required++["notApplicableCriteria"])) (keys outcome)) 400 "Outcome requires status, satisfiedCriteria, artifacts; notApplicableCriteria is optional"
 require (at outcome "status" `elem` ["Completed","Unresolved"]) 400 "Outcome status must be Completed or Unresolved"
 strings (get outcome "satisfiedCriteria") "satisfiedCriteria" False
 strings (get outcome "artifacts") "artifacts" False
 require (case skipped of Object _ -> True; _ -> False) 400 "notApplicableCriteria must map exact conditional criteria to reasons"
 forM_ (pairs skipped) $ \(criterion,reason) -> do
  require (str criterion `elem` criteria && "If " `T.isPrefixOf` criterion && str criterion `notElem` items outcome "satisfiedCriteria") 400 "Only an unsatisfied, explicit If criterion can be not applicable"
  void $ textField (obj [("reason",reason)]) "reason" 4000
 when (at outcome "status" == "Completed") $ require (not (null (items response "evidence")) && all (`elem` (items outcome "satisfiedCriteria" ++ map str (keys skipped))) criteria) 400 "Completed outcome requires evidence for all applicable completion criteria"
 pure outcome
begin :: Service -> Text -> Value -> IO ()
begin s a turn = do
 found <- findWork s (at turn "id")
 let routine = has (get turn "origin") "routine"
     first = obj [("callId",get turn "id"),("addressedTo",str a),("causedBy",Null),("node",str (if routine then "ReadyToWork" else "Assessing")),("state",str "Running"),("request",get turn "input"),("attempt",num 1)]
     initial = obj [("workloadId",get turn "id"),("originalIntent",get turn "input"),("tracked",Bool routine),("task",obj [("taskId",str ("task_"<>at turn "id")),("taskType",str (if routine then "automated" else "work")),("specification",Null)]),("origin",merge (obj [("agent",str a),("call",get turn "id")]) (get turn "origin")),("calls",arr [first]),("decisions",arr []),("outcome",Null)]
     (w,c) = fromMaybe (initial,first) found
     updated = put "attempt" (get turn "attempt" `fallback` num 1) (if get c "output" == Null then put "state" (str "Running") (remove ["error"] c) else c)
 saveWork s (withCall w updated)
conversation :: Service -> Text -> Value -> Value -> IO Value
conversation s a turn state = do
 manifests <- fmap obj $ fmap catMaybes $ forM ["identity","computer-use","host-control","host-facts","corpora-state"] $ \name -> do
  let p = agentRoot s a </> "manifests" </> T.unpack name <.> "md"
  exists <- doesFileExist p
  if exists then Just . (name,) . str <$> readText p else pure Nothing
 memo <- (get <$> readMemo (workspaceRoot s a) <*> pure "content") `catch` (\(APIError _ e) -> pure (obj [("error",str e)]))
 let turns = items state "turns"; current = at turn "id"
     chat = takeLast 20 [let matching = fromMaybe empty (findId (at m "turn") turns) in if at m "role" == "user" && text (get matching "batch_id" `fallback` get matching "id") /= current && at matching "status" `elem` ["running","failed","interrupted"] then put "underPrevAgencyReview" (Bool True) m else m | m <- items state "chat", not (has (get m "origin") "group")]
 pure $ obj [("manifests",remove ["corpora-state"] manifests),("staticContext",get manifests "corpora-state" `fallback` str ""),("instantContext",obj [("chat",arr chat),("memo",memo)]),("inputs",get state "agency_batch" `fallback` arr [obj [("content",get turn "input")]])]
 where takeLast n xs = drop (length xs-n) xs
recordDecision :: Service -> Text -> Value -> IO ()
recordDecision s a record = do
 writeJSON (archivePath s a ("decisions/"<>at record "decisionId")) record
 (w,_) <- getWork s (at record "callId")
 let update d = if get d "decisionId" == get record "decisionId" then merge d (obj [(k,get record k) | k <- ["accepted","response","error","transition"],has record k]) else d
 saveWork s (put "decisions" (arr (map update (items w "decisions"))) w)
accept :: Service -> Text -> Value -> Text -> Text -> IO ()
accept s a record before after = recordDecision s a (merge record (obj [("accepted",Bool True),("transition",obj [("before",str before),("event",get record "hostEvent" `fallback` get (get record "response") "event"),("after",str (transition before (at (get record "response") "event") after)),("nextNode",str after)])]))
 where transition b e def = fromMaybe def $ lookup (b,e) [(("Assessing","FitsSpecialization"),"ReadyToWork"),(("Assessing","OutsideSpecialization"),"ChiefTriage"),(("ChiefTriage","SpecialistSelected"),"Assessing"),(("ChiefTriage","NewSpecialistNeeded"),"CreatingSapi"),(("ChiefTriage","RequestUnclear"),"WaitingForAdmin"),(("ChiefTriage","FitsSpecialization"),"ReadyToWork")]
decide :: Service -> Run -> Value -> Value -> Text -> IORef [Value] -> IO (Value,Value)
decide s run turn state node logs = do
 (rendered,record) <- locked s $ do
  source <- templates s >>= maybe (failure 400 "Unknown decision node") pure . find ((==node) . (`at` "node"))
  (w,c) <- getWork s (at turn "id")
  conv <- conversation s (runOwner run) turn state
  chief <- DB.mainAgent s
  members <- team s
  extra <- if has state "agency_batch" then ("\n\n" <>) <$> prompt s "agency-chat" else pure ""
  scheduled <- if has (get w "origin") "routine" then ("\n\n" <>) <$> prompt s "scheduled-execution" else pure ""
  wiki <- prompt s "notes-wiki"
  envelope <- prompt s "decision-envelope"
  let instruction = at source "content" <> extra <> scheduled
      context = obj [("originalIntent",get w "originalIntent"),("task",get w "task"),("tracked",get w "tracked"),("currentCall",c),("selfId",str (runOwner run)),("chiefId",str chief),("team",arr members),("routingHistory",arr [obj [(k,get call k) | k <- ["callId","addressedTo","node"]] | call <- items w "calls"]),("conversation",conv),("observation",get c "observation")]
      rendered = render envelope [("node",node),("instruction",instruction),("notes_wiki",render wiki [("notes_example",T.pack (repositoryRoot s </> "prompts/examples/jarvis-notes.html"))]),("context",jsonText context),("events",T.intercalate ", " (sort (eventsFor node)))]
  (model,effort) <- modelDefaults
  policy <- executionSettings s (runOwner run)
  i <- newId
  t <- now
  let digest = T.pack (concatMap (\b -> let v=showHex b "" in if length v==1 then '0':v else v) (BS.unpack (hash (TE.encodeUtf8 instruction))))
      record = obj [("decisionId",str i),("callId",get turn "id"),("node",str node),("template",get source "template"),("promptHash",str digest),("templatePath",get source "path"),("renderedPrompt",str rendered),("model",str model),("effort",str (if at policy "mode" == "deep" then "xhigh" else effort)),("created",str t),("accepted",Bool False)]
      summary = merge (obj [(k,get record k) | k <- ["decisionId","callId","node","promptHash","accepted"]]) (obj [("agent",str (runOwner run)),("promptTemplate",get record "template")])
  saveWork s (put "decisions" (arr (items w "decisions"++[summary])) w)
  writeJSON (archivePath s (runOwner run) ("decisions/"<>i)) record
  pure (rendered,record)
 logIndex <- length <$> readIORef logs
 modifyIORef' logs (++[obj [("role",str node),("prompt",str rendered),("session",Null)]])
 let updateLog extra = modifyIORef' logs (\entries -> [if index==logIndex then merge entry extra else entry | (index,entry)<-zip [0::Int ..] entries])
 rawResponse <- newIORef Nothing
 result <- try $ do
  raw <- invoke s run rendered
  writeIORef rawResponse (Just raw)
  activity <- readIORef (runActivity run)
  updateLog (obj ([("session",get activity "session"),("answer",str raw)]++[("warning",get activity "warning") | has activity "warning"]))
  require (T.length raw <= 100000) 400 "Decision response exceeds 100000 characters"
  let response = parseJSONText raw
  require (at response "event" `elem` eventsFor node) 400 ("Unknown decision event for "<>node)
  require (all (`elem` (fieldsFor (at response "event")++["event","reason","evidence"])) (keys response)) 400 "Unknown field in decision response"
  void (textField response "reason" 4000)
  strings (get response "evidence") "evidence" False
  pure (response,merge record (obj [("rawResponse",str raw),("response",response)]))
 case result of
  Left (e::SomeException) -> do
   activity <- readIORef (runActivity run)
   updateLog (obj [("session",get activity "session")])
   raw <- readIORef rawResponse
   let failed=put "error" (str (exceptionText e)) (maybe record (\value -> put "rawResponse" (str value) record) raw)
   locked s (recordDecision s (runOwner run) failed)
   throwIO e
  Right value@(_,record') -> locked s (recordDecision s (runOwner run) record') >> pure value
exceptionText :: SomeException -> Text
exceptionText e = case fromException e of Just (APIError _ m) -> m; _ -> T.pack (displayException e)
validateTarget :: Service -> Value -> Text -> Text -> IO ()
validateTarget s w source target = do
 chief <- DB.mainAgent s
 require (target /= source && (source == chief || target == chief)) 400 "Routes are Chief → Sapi or Sapi → Chief"
 void (resolve s target False)
 state <- agentState s target
 require (not (any ((`elem` ["queued","running"]) . (`at` "status")) (items state "turns"))) 409 "Recipient is busy; responsibility remains with the sender"
 works <- DB.values s "workloads"
 require (not (any (\c -> at c "state" == "Queued" && at c "addressedTo" == target) (concatMap (`items` "calls") works))) 409 "Recipient already has an accepted call"
 require (length (items w "calls") <= 8) 409 "Routing limit reached; Admin must resolve the request"
 require (target == chief || not (any ((==target) . (`at` "addressedTo")) (items w "calls"))) 409 "This specialist already assessed the request; ask Admin to resolve routing"
transfer :: Service -> Run -> Value -> Value -> Value -> IO Text
transfer s run turn response record = do
 (w,c) <- getWork s (at turn "id")
 stopped <- readIORef (runCancel run)
 require (not stopped) 409 "Stopped before handoff acceptance"
 let target=at c "target"
 validateTarget s w (runOwner run) target
 request <- textField response "request" 16000
 i <- newId
 chief <- DB.mainAgent s
 let child=obj [("callId",str i),("addressedTo",str target),("causedBy",get turn "id"),("node",str (if target==chief then "ChiefTriage" else "Assessing")),("state",str "Queued"),("request",str request),("handoffReason",get response "reason"),("attempt",num 1)]
     reply="Delegated to "<>target<>"."
     updated=merge c (obj [("state",str "Delegated"),("output",str reply),("node",str "Delegation")])
 saveWork s (put "calls" (arr (items (withCall w updated) "calls"++[child])) (put "tracked" (Bool True) w))
 accept s (runOwner run) record "Delegation" (at child "node")
 pure reply
applyDecision :: Service -> Text -> Maybe Text -> Text -> IO Value
applyDecision s owner current decision = do
 identity <- maybe (failure 409 "Delegation requires this call's recorded Delegation decision") pure current
 (w,c) <- getWork s identity
 require (at c "node"=="Delegation" && any (\d -> at d "decisionId"==decision && at d "callId"==identity && at d "node"=="Delegation") (items w "decisions")) 409 "Delegation requires this call's recorded Delegation decision"
 record <- readJSON (archivePath s owner ("decisions/"<>decision)) empty
 require (get record "error"==Null && at (get record "response") "event"=="HandoffPrepared") 409 "Delegation decision has not produced a valid response"
 existing <- case find ((==str identity) . (`get` "causedBy")) (items w "calls") of
  Just child -> pure child
  Nothing -> do
   runs <- readMVar (serviceRuns s)
   run <- maybe (failure 409 "AgencyRun is no longer active") pure (M.lookup identity runs)
   void (transfer s run (obj [("id",str identity)]) (get record "response") record)
   (updated,_) <- getWork s identity
   maybe (failure 409 "Delegation acceptance was not saved") pure (find ((==str identity) . (`get` "causedBy")) (items updated "calls"))
 pure (obj [("saved",Bool True),("callId",get existing "callId"),("target",get existing "addressedTo")])
runDecision :: Service -> Run -> Value -> Value -> IO (Text,[Value])
runDecision s run turn state = do
 locked s (begin s (runOwner run) turn)
 logs <- newIORef []
 let loop n = do
      require (n < 12) 409 "Decision transition limit reached; Admin must resolve the request"
      (w,c) <- locked s (getWork s (at turn "id"))
      if get c "output" /= Null then pure (at c "output") else do
       let node=at c "node"
       (response,record) <- decide s run turn state node logs
       result <- locked s $ do
        (current,call) <- getWork s (at turn "id")
        stopped <- readIORef (runCancel run)
        require (not stopped) 409 "Stopped by Admin"
        chief <- DB.mainAgent s
        let event=at response "event"; owner=runOwner run
            finish work updated next = do
             let following=put "observation" response (put "node" (str next) updated)
             saveWork s (withCall work following)
             accept s owner record node next
             pure (if get following "output" /= Null then Just (at following "output") else Nothing)
        case node of
         _ | node `elem` ["Assessing","ChiefTriage"] -> case event of
          "FitsSpecialization" -> if at response "mode" == "Repl" then do
           require (not (boolean (get current "tracked"))) 409 "An accepted Task must execute and report its completion criteria"
           reply <- textField response "reply" 64000
           finish current (merge call (obj [("state",str "Completed"),("output",str reply)])) "Outcome"
           else require (at response "mode" == "Exec") 400 "FitsSpecialization requires mode Repl or Exec" >> finish (put "tracked" (Bool True) current) call "ReadyToWork"
          "OutsideSpecialization" -> finish current (if owner==chief then call else put "target" (str chief) call) (if owner==chief then "ChiefTriage" else "Delegation")
          "SpecialistSelected" -> do target <- resolve s (at response "target") False; validateTarget s current owner target; finish current (put "target" (str target) call) "Delegation"
          "NewSpecialistNeeded" -> finish current call "CreatingSapi"
          "RequestUnclear" -> do question <- textField response "question" 4000; finish (put "tracked" (Bool True) current) (merge call (obj [("state",str "WaitingForAdmin"),("output",str question)])) "WaitingForAdmin"
          _ -> failure 400 "Unknown decision event"
         "CreatingSapi" -> do
          require (owner==chief) 403 "Only Chief can create a Sapi"
          name <- validName response
          role <- textField response "role" 60
          rows <- DB.agents s
          created <- case find ((==T.toCaseFold name) . T.toCaseFold . (`at` "name")) rows of
           Just row -> require (at row "role" == role) 409 "Name already exists with a different role" >> pure row
           Nothing -> createAgent s (obj [("name",str name),("role",str role),("manager",str owner)])
          finish current (merge call (obj [("target",get created "id"),("creation",obj [("name",str name),("role",str role)]),("creationReceipt",obj [("agent",created),("created",Bool True)])])) "Delegation"
         "ReadyToWork" -> do
          taskType <- textField response "taskType" 60
          let spec=get response "specification"; previous=get (get current "task") "specification"
          require (sort (keys spec)==sort ["objective","inputs","expectedOutputs","completionCriteria"]) 400 "Task specification requires objective, inputs, expectedOutputs, completionCriteria"
          void (textField spec "objective" 16000)
          forM_ ["inputs","expectedOutputs","completionCriteria"] $ \k -> strings (get spec k) k (k /= "inputs")
          require (all (`elem` items spec "completionCriteria") (items previous "completionCriteria")) 400 "A handoff cannot remove accepted completion criteria"
          let task=merge (get current "task") (obj [("taskType",str (if has (get current "origin") "routine" then "automated" else taskType)),("specification",spec)])
          finish (put "task" task current) call "Execution"
         "Delegation" -> Just <$> transfer s run turn response record
         "Execution" -> if event == "OutsideSpecialization" then finish current (put "target" (str chief) call) (if owner==chief then "ChiefTriage" else "Delegation") else do
          reply <- textField response "reply" 64000
          outcome <- validateOutcome response (items (get (get current "task") "specification") "completionCriteria")
          finish (put "outcome" (merge outcome (obj [("reply",str reply),("evidence",get response "evidence"),("author",str owner)])) current) (merge call (obj [("state",get outcome "status"),("output",str reply)])) "Outcome"
         _ -> failure 409 "Unknown decision state"
       maybe (loop (n+1)) pure result
 output <- loop (0::Int) `catch` (\(e::SomeException) -> do
  locked s $ do
   (work,_) <- getWork s (at turn "id")
   case listToMaybe (reverse [d | d<-items work "decisions",get d "callId"==get turn "id"]) of
    Just summary | not (boolean (get summary "accepted")) -> do
     record <- readJSON (archivePath s (runOwner run) ("decisions/"<>at summary "decisionId")) empty
     recordDecision s (runOwner run) (put "error" (str (exceptionText e)) record)
    _ -> pure ()
  readIORef logs >>= throwIO . RunFailure (exceptionText e))
 (output,) <$> readIORef logs
reconcileWorks :: Service -> IO ()
reconcileWorks s = do
 turns <- DB.turns s
 works <- DB.values s "workloads"
 forM_ works $ \w -> do
  let updated = [case findId (at c "callId") turns of Just t | at t "status" `elem` ["failed","interrupted","cancelled"] && get c "output" == Null -> merge c (obj [("state",str (T.toTitle (at t "status"))),("error",get t "error")]); _ -> c | c <- items w "calls"]
  when (updated /= items w "calls") $ saveWork s (put "calls" (arr updated) w)
pendingWorks :: Service -> IO ()
pendingWorks s = do
 works <- DB.values s "workloads"
 existing <- DB.turns s
 forM_ works $ \w -> forM_ (items w "calls") $ \c -> when (at c "state" == "Queued" && get c "causedBy" /= Null && isNothing (findId (at c "callId") existing)) $ do
  let a=at c "addressedTo"; parent=fromMaybe empty (find ((==get c "causedBy") . (`get` "callId")) (items w "calls")); origin=merge (remove ["agent","call"] (get w "origin")) (obj [("workloadId",get w "workloadId"),("taskId",get (get w "task") "taskId"),("caller",get parent "addressedTo"),("parentCall",get c "causedBy")])
  time <- now
  let turn=obj [("id",get c "callId"),("flow",str "chat"),("input",get c "request"),("status",str "queued"),("created",str time),("attempt",num 1),("origin",origin),("batchable",Bool (has origin "routine"))]
  modifyState s a $ \state -> if isJust (findId (at c "callId") (items state "turns")) then state else merge state (obj [("turns",arr (items state "turns"++[turn])),("chat",arr (items state "chat"++[obj [("role",str "user"),("content",get c "request"),("turn",get c "callId"),("time",str time),("origin",origin)]]))])
  DB.project s a
clarify :: Service -> Text -> Text -> Text -> IO Text
clarify s a wid message = do
 works <- DB.values s "workloads"
 w <- maybe (failure 409 "Clarification requires the waiting Chief call") pure (find ((==wid) . (`at` "workloadId")) works)
 chief <- DB.mainAgent s
 let previous=last (items w "calls")
 require (at previous "state" == "WaitingForAdmin" && a==chief) 409 "Clarification requires the waiting Chief call"
 i <- newId
 let call=obj [("callId",str i),("addressedTo",str a),("causedBy",get previous "callId"),("node",str "ChiefTriage"),("state",str "Queued"),("request",str message),("activation",str "RequestClarified"),("attempt",num 1)]
 saveWork s (put "calls" (arr (items w "calls"++[call])) w)
 pendingWorks s
 pure i
workTasks :: Service -> Text -> Bool -> IO Value
workTasks s a full = do
 works <- DB.values s "workloads"
 rows <- forM [w | w <- works,boolean (get w "tracked"),any ((==a) . (`at` "addressedTo")) (items w "calls")] $ \w -> do
  let lastCall=last (items w "calls")
  decisions <- forM (items w "decisions") $ \d -> if full then merge d <$> readJSON (archivePath s (at d "agent") ("decisions/"<>at d "decisionId")) empty else pure d
  pure $ merge (obj [(k,get w k) | k <- ["task","workloadId","originalIntent","calls","outcome"]]) (obj [("execution",obj [("state",get lastCall "state"),("owner",get lastCall "addressedTo"),("currentCall",get lastCall "callId"),("attempt",get lastCall "attempt")]),("decisions",arr decisions)])
 pure (obj [("tasks",arr rows)])
taskList :: Service -> Text -> IO Value
taskList s a = do
 tasks <- items <$> workTasks s a False <*> pure "tasks"
 pure $ obj [("tasks",arr (reverse [let body=get (get t "task") "specification" `fallback` obj [("objective",get t "originalIntent")]; execution=get t "execution"; calls=items t "calls" in obj [("id",get t "workloadId"),("title",get body "objective"),("taskType",get (get t "task") "taskType"),("state",get execution "state"),("owner",get execution "owner"),("sender",get (head calls) "addressedTo"),("body",str (jsonText body <> "\n")),("result",get (get t "outcome") "reply"),("error",get (last calls) "error")] | t <- tasks]))]
workSummaries :: [Value] -> [Value]
workSummaries works = [let c=last (items w "calls") in obj [("taskType",get (get w "task") "taskType"),("id",get w "workloadId"),("taskId",get (get w "task") "taskId"),("origin",get w "origin"),("callId",get c "callId"),("owner",get c "addressedTo"),("state",get c "state"),("participants",arr (nub (map (`get` "addressedTo") (items w "calls")))),("output",get c "output"),("error",get c "error"),("decisions",num (length (items w "decisions"))),("calls",num (length (items w "calls")))] | w <- works,boolean (get w "tracked")]

{-# LANGUAGE OverloadedStrings #-}
module Sapiens.GroupModel where

import Control.Monad
import Data.Aeson hiding (pairs)
import qualified Data.Aeson.KeyMap as KM
import Data.List
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory
import System.Random
import Sapiens.Types
import qualified Sapiens.Store as DB
import qualified Sapiens.Population as Population
import Sapiens.Memo

data GroupRequest = GroupRequest
 { requestId :: RunId, requestTarget :: AgentId, requestStatus :: TurnStatus
 , requestSettled :: Bool, requestFields :: Object
 } deriving (Eq, Show)
instance FromJSON GroupRequest where
 parseJSON = withObject "Group request" $ \o -> GroupRequest <$> o .: "id" <*> o .: "target" <*> o .: "status" <*> o .: "settled" <*> pure (foldr KM.delete o ["id","target","status","settled"])
instance ToJSON GroupRequest where
 toJSON request = mergeFields [("id",toJSON (requestId request)),("target",toJSON (requestTarget request)),("status",toJSON (requestStatus request)),("settled",Bool (requestSettled request))] (Object (requestFields request))
readRequests :: Value -> IO [GroupRequest]
readRequests group = decodeValue 500 (get group "requests")

getGroup :: Service -> Text -> Bool -> IO Value
getGroup s gid active = do
 g <- DB.values s DB.Groups >>= maybe (failure 404 "Unknown Group") pure . findId gid
 require (not active || not (boolean (get g "archived"))) 409 "Restore this Group before changing its work"
 pure g
storeGroup :: Service -> Value -> IO ()
storeGroup s g = DB.putValue s DB.Groups (at g "id") g
append :: Text -> Value -> Value -> Value
append key value = appendItems key [value]
replace :: Text -> Value -> Value -> Value
replace = replaceItem
saveGroup :: Service -> Value -> Text -> Text -> Value -> IO Value
saveGroup s group actor action detail = do
 event <- eventRecord actor action detail
 let updated = append "events" event (merge group (obj [("revision",num (int (get group "revision")+1)),("updated",get event "created")]))
 storeGroup s updated
 pure updated
eventRecord :: Text -> Text -> Value -> IO Value
eventRecord actor action detail = do
 i <- newId; t <- now
 pure (obj [("id",str i),("actor",str actor),("action",str action),("detail",detail),("created",str t)])
message :: Text -> Text -> IO Value
message author content = do
 i <- newId; t <- now
 pure (obj [("id",str i),("author",str author),("text",str content),("created",str t)])
authorizeGroup :: Service -> Value -> Text -> GroupAccess -> IO ()
authorizeGroup s group actor mode = unless (actor == "admin") $ do
 Population.requireActive s actor
 chief <- DB.mainAgent s
 let allowed = case mode of
       ChiefOnly -> actor == chief
       Management -> actor `elem` [chief,at group "lead"]
       Member -> str actor `elem` items group "members"
 require allowed 403 (if mode == ChiefOnly then "Only Chief can perform this operation" else if mode == Management then "Only Chief or the Lead can manage members" else "Only Group members can contribute")
validateMembers :: Service -> Value -> Value -> IO [Value]
validateMembers s value lead = do
 let members = list value
 require (case value of Array _ -> length members >= 2 && length members <= 100 && all (\v -> case v of String _ -> True; _ -> False) members; _ -> False) 400 "A Group needs 2–100 distinct Sapis, including its Lead"
 require (length (nub members) == length members && lead `elem` members) 400 "Members must be distinct and include exactly one Lead"
 mapM_ (Population.requireActive s . text) members
 pure members
capacity :: Service -> [Value] -> Maybe Text -> IO ()
capacity s members exclude = do
 groups <- filter (\g -> not (boolean (get g "archived")) && Just (at g "id") /= exclude) <$> DB.values s DB.Groups
 forM_ members $ \m -> require (length (filter (elem m . (`items` "members")) groups) < 11) 409 "A Sapi can belong to at most 11 active Groups"
shuffle :: [a] -> IO [a]
shuffle = getStdRandom . uniformShuffleList
folder :: Service -> Text -> IO FilePath
folder s gid = do
 void (getGroup s gid False)
 let path = workspaceRoot s gid
 createDirectoryIfMissing True path
 pure path
introduction :: Service -> Value -> IO [Value]
introduction s group = do
 rows <- DB.agents s; chief <- DB.mainAgent s
 let name i = maybe "" (`at` "name") (findId i rows)
     lead = name (at group "lead")
     roster = T.intercalate ", " ["@" <> name (text m) | m <- get group "lead" : filter (/= get group "lead") (items group "members")]
     purpose = T.strip (at group "description")
     admin = if T.null purpose then "I need " <> at group "name" <> " to work together. Let’s define the first task here." else "I need this group to work on:\n\n" <> purpose
 messages <- sequence [message "admin" admin, message chief ("I’ve created " <> at group "name" <> " with " <> roster <> ". @" <> lead <> " will lead this group."),message (at group "lead") ("Hi! I’m " <> lead <> ", Lead of this group. Together we can manage a shared memo/wiki, workflows, a Scrum backlog or ad hoc tasks, and automated operations.")]
 pure (map (put "source" (str "group-introduction")) messages)
createGroup :: Service -> Value -> Text -> IO Value
createGroup s input actor = do
 authorizeGroup s empty actor ChiefOnly
 require (all (`elem` ["name","description","lead","members"]) (keys input)) 400 "Unknown Group field"
 name <- textField input "name" 60
 let description = get input "description" `fallback` str ""
 require (case description of String t -> T.length t <= 2000; _ -> False) 400 "Description must be text, at most 2000 characters"
 members <- validateMembers s (get input "members") (get input "lead")
 capacity s members Nothing
 order <- shuffle (filter (/= get input "lead") members)
 gid <- fresh "group_"; created <- now; color <- ( ["#48c99c", "#ba85df", "#74b9ed", "#edbd65", "#e891ae"] !!) <$> randomRIO (0,4)
 let group = obj [("id",str gid),("name",str name),("description",description),("lead",get input "lead"),("members",arr members),("strip_order",arr (get input "lead":order)),("color",str color),("archived",Bool False),("created",str created),("updated",str created),("revision",num 0),("messages",arr []),("requests",arr []),("tasks",arr []),("events",arr [])]
 messages <- introduction s group
 saved <- saveGroup s (put "messages" (arr messages) group) actor "created" (str name)
 void (folder s gid)
 pure saved
updateGroup :: Service -> Text -> Value -> Text -> IO Value
updateGroup s gid input actor = do
 group <- getGroup s gid False
 require (all (`elem` ["name","description","members","lead","archived","revision"]) (keys input)) 400 "Unknown Group field"
 authorizeGroup s group actor Management
 require (get input "revision" == get group "revision" && get input "revision" /= Null) 409 "Group changed; refresh before saving"
 when ((has input "lead" && get input "lead" /= get group "lead") || has input "archived") $ authorizeGroup s group actor ChiefOnly
 when (has input "archived") $ require (case get input "archived" of Bool _ -> True; _ -> False) 400 "archived must be a boolean"
 require (not (boolean (get group "archived")) || get input "archived" == Bool False) 409 "Restore this Group before editing it"
 let lead = get input "lead" `fallback` get group "lead"
 members <- validateMembers s (get input "members" `fallback` get group "members") lead
 let archived = get input "archived" `fallback` get group "archived"; removed = items group "members" \\ members
 unless (boolean archived) $ capacity s members (Just gid)
 require (not (any (\r -> get r "target" `elem` removed && at r "status" `elem` ["queued","running"]) (items group "requests"))) 409 "Finish or cancel the departing member’s Group calls first"
 require (not (any (\t -> get t "assignee" `elem` removed && not (boolean (get t "deleted")) && at t "state" /= "done") (items group "tasks"))) 409 "Reassign the departing member’s unfinished tasks first"
 name <- if has input "name" then str <$> textField input "name" 60 else pure (get group "name")
 let description = get input "description" `fallback` get group "description"
 require (case description of String t -> T.length t <= 2000; _ -> False) 400 "Description must be text, at most 2000 characters"
 let oldOrder = filter (\m -> m `elem` members && m /= lead) (items group "strip_order")
 additions <- shuffle [m | m <- members,m /= lead,m `notElem` oldOrder]
 requests <- if not (boolean archived) then pure (items group "requests") else forM (items group "requests") $ \r -> if at r "status" /= "queued" then pure r else do
   turn <- findId (at r "id") <$> DB.turns s
   if maybe False ((== "running") . (`at` "status")) turn then pure (put "status" (str "running") r) else do
     forM_ turn $ \t -> when (at t "status" == "queued") $ modifyTurns s (at r "target") (\v -> if toJSON (turnId v) == get r "id" then v { turnStatus = Cancelled } else v) >> DB.project s (at r "target")
     pure (put "status" (str "cancelled") r)
 let updated = merge group (obj [("lead",lead),("name",name),("description",description),("members",arr members),("strip_order",arr (lead:oldOrder++additions)),("archived",archived),("requests",arr requests)])
 saveGroup s updated actor (if lead /= get group "lead" then "leadership transferred" else if boolean archived then "archived" else "updated") (obj [("lead",lead),("members",arr members)])
snapshotGroups :: Service -> IO [Value]
snapshotGroups s = do
 groups <- DB.values s DB.Groups; rows <- DB.agents s
 forM groups $ \g -> do
  root <- folder s (at g "id"); meta <- memoMetadata root
  let person i = fromMaybe empty (findId i rows)
  pure $ merge g (obj [("kind",str "group"),("role",str (if T.null (at g "description") then "Shared Group workspace" else at g "description")),("face",get (person (at g "lead")) "face"),("stripes",arr [get (person (text m)) "color" | m <- items g "strip_order"]),("workspace",str (T.pack root)),("notes",meta)])
groupFacts :: Service -> Text -> IO [Value]
groupFacts s actor = do
 chief <- DB.mainAgent s; groups <- DB.values s DB.Groups
 forM [g | g <- groups,not (boolean (get g "archived")),actor == chief || str actor `elem` items g "members"] $ \g -> do
  root <- folder s (at g "id")
  pure (obj ([(k,get g k) | k <- ["id","name","lead","members","revision","tasks"]] ++ [("workspace",str (T.pack root))]))

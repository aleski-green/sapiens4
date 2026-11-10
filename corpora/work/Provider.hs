{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
module Provider where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.Aeson hiding (pairs)
import Data.Aeson.Types (Parser)
import Text.Read (readMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import Data.Char (toUpper, toLower)
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory
import System.Environment
import System.Exit
import System.FileLock
import System.FilePath
import System.Info
import System.IO
import System.Process hiding (runProcess)
import System.Timeout
#ifndef mingw32_HOST_OS
import System.Posix.Signals
import System.Posix.Files (setFileMode)
#endif
import Types
import Population (executionSettings, activeModelSettings, ModelSelection(..), ModelSettingsDraft(..))
import qualified Computer as Computer

data ProviderEvent
 = SessionStarted Text | ToolStarted Text Text | ToolCompleted Text Text
 | AgentMessage Text | ProviderFailed Value | OtherEvent
 deriving (Eq, Show)
instance FromJSON ProviderEvent where
 parseJSON = withObject "Provider event" $ \o -> do
  kind <- o .: "type" :: Parser Text
  case kind of
   "thread.started" -> SessionStarted <$> o .: "thread_id"
   "turn.failed" -> pure (ProviderFailed (Object o))
   "item.started" -> itemEvent True =<< o .: "item"
   "item.completed" -> itemEvent False =<< o .: "item"
   _ -> pure OtherEvent -- Provider protocols may add events we do not consume.
  where
  itemEvent started = withObject "Provider item" $ \item -> do
   kind <- item .: "type" :: Parser Text
   let value=Object item
       label=T.take 200 (text (get value "command" `fallback` get value "tool" `fallback` str kind))
       identity=text (get value "id" `fallback` str label)
   if kind `elem` ["command_execution","mcp_tool_call","web_search","file_change"] then
    pure ((if started then ToolStarted else ToolCompleted) identity label)
   else if not started && kind=="agent_message" then AgentMessage <$> item .: "text" else pure OtherEvent

data ProviderState = ProviderState
 { providerTools :: M.Map Text Text, providerMessage :: Maybe Text }

providerStep :: Double -> ProviderEvent -> ProviderState -> Value -> Validation (ProviderState,Value)
providerStep time event state activity = case event of
 ProviderFailed details -> Left (APIError 500 ("Provider turn failed: " <> jsonText details))
 _ -> Right (updated,mergeFields [("updated",toJSON time),("phase",str (if M.null tools then "Waiting for model" else "Running tool")),("tool",str (fromMaybe "" (listToMaybe (M.elems tools))))] reported)
 where
 updated=case event of
  ToolStarted key label -> state { providerTools=M.insert key label (providerTools state) }
  ToolCompleted key _ -> state { providerTools=M.delete key (providerTools state) }
  AgentMessage message -> state { providerMessage=Just message }
  _ -> state
 tools=providerTools updated
 reported=case event of
  SessionStarted session -> put "session" (str session) activity
  ToolCompleted _ label -> put "last_action" (str label) activity
  _ -> activity

modelDefaults :: IO ModelConfig
modelDefaults = ModelConfig CodexProvider <$> (maybe "gpt-6-sol" T.pack <$> lookupEnv "SAPIENS_CODEX_MODEL") <*> (maybe "high" T.pack <$> lookupEnv "SAPIENS_CODEX_REASONING_EFFORT")

resolveModelConfig :: ExecutionSettings -> ModelConfig -> ModelConfig
resolveModelConfig settings defaults = case executionMode settings of
 Normal -> defaults
 Deep -> defaults { configuredEffort = "xhigh" }

-- Resolve once under the service lock when a run starts. Active selections are
-- explicit: the legacy Normal/Deep mode must not overwrite their validated effort.
runModelSettings :: Service -> Text -> IO ModelConfig
runModelSettings s owner = do
 active <- activeModelSettings s
 case active of
  Just configured -> do
   let choice = M.findWithDefault (modelSettingsDefault configured) owner (modelSettingsOverrides configured)
   pure (ModelConfig (selectionProvider choice) (selectionModel choice) (selectionEffort choice))
  Nothing -> do
   defaults <- modelDefaults
   policy <- executionSettings s owner
   pure (resolveModelConfig policy defaults)

codexArguments :: FilePath -> ModelConfig -> [String]
codexArguments workdir config =
 codexConfig ++ ["exec","-c","model_reasoning_effort=" ++ T.unpack (jsonText (str (configuredEffort config))),"-c","model=" ++ T.unpack (jsonText (str (configuredModel config))),"--skip-git-repo-check","--json","--dangerously-bypass-approvals-and-sandbox","--cd",workdir,"--color","never","-"]

-- Discovery is an on-demand catalog read, never an agent turn. Keep it outside
-- the service state lock; the process and every page share one deadline.
codexModels :: IO Value
codexModels = do
 result <- timeout 30000000 $ bracket
  (profileLock Shared >>= maybe (failure 409 "Codex sign-in is changing. Finish or cancel sign-in, then retry model discovery.") pure)
  unlockFile (const discover)
 maybe (failure 504 "Codex model discovery timed out. Try again.") pure result
 where
 discover = do
  binary <- codexBinary >>= maybe (failure 503 "Codex CLI was not found on this host.") pure
  workdir <- getTemporaryDirectory
  environment <- codexEnvironment
  bracket (createProcess (proc binary (codexConfig ++ ["app-server","--stdio"])) {env=Just environment,cwd=Just workdir,std_in=CreatePipe,std_out=CreatePipe,std_err=CreatePipe,create_group=True,use_process_jobs=True,detach_console=os=="mingw32"}) cleanup $ \handles -> do
   (hin,hout,herr) <- case handles of
    (Just i,Just o,Just e,_) -> pure (i,o,e)
    _ -> failure 502 "Codex discovery could not open its pipes."
   mapM_ (`hSetBinaryMode` True) [hin,hout,herr]
   buffer <- newIORef BS.empty
   let send value = BS.hPut hin (TE.encodeUtf8 (jsonText value <> "\n")) >> hFlush hin
       line = do
        bytes <- readIORef buffer
        case BC.elemIndex '\n' bytes of
         Just index -> do
          writeIORef buffer (BS.drop (index+1) bytes)
          pure (BS.take index bytes)
         Nothing -> do
          chunk <- BS.hGetSome hout 8192
          require (not (BS.null chunk)) 502 "Codex closed the model discovery connection."
          require (BS.length bytes + BS.length chunk <= 1048576) 502 "Codex model response is too large."
          writeIORef buffer (bytes <> chunk)
          line
       receive ident remaining = do
        require (remaining > (0 :: Int)) 502 "Too many Codex discovery notifications."
        raw <- line
        value <- either (const (failure 502 "Codex returned invalid discovery JSON.")) pure (eitherDecodeStrict' raw)
        if get value "id" /= num ident then receive ident (remaining-1) else do
         require (not (has value "error")) 502 "Codex could not list models. Check its login and CLI version."
         require (has value "result") 502 "Codex discovery response has no result."
         pure (get value "result")
       request ident method params = send (obj [("id",num ident),("method",str method),("params",params)]) >> receive ident 1024
       pages ident seen cursor collected = do
        require (ident <= 22) 502 "Codex returned too many model pages."
        page <- request ident "model/list" (obj [("cursor",cursor),("limit",num 100),("includeHidden",Bool False)])
        rows <- field 502 page "data" :: IO [Value]
        require (length collected + length rows <= 2000) 502 "Codex returned too many models."
        models <- traverse catalogModel rows
        let next=get page "nextCursor"; allModels=collected ++ models
        case next of
         Null -> pure (obj [("data",arr (filter (\m -> get m "hidden" /= Bool True) allModels))])
         String token -> do
          require (not (T.null token) && token `notElem` seen) 502 "Codex returned an invalid pagination cursor."
          pages (ident+1) (token:seen) next allModels
         _ -> failure 502 "Codex returned an invalid pagination cursor."
       drain = do
        bytes <- BS.hGetSome herr 8192
        unless (BS.null bytes) drain
   withAsync drain $ \_ -> do
    void (request 1 "initialize" (obj [("clientInfo",obj [("name",str "sapiens4"),("version",str "1")]),("capabilities",obj [("explicitGatewayOauth",Bool True)])]))
    send (obj [("method",str "initialized")])
    pages 2 [] Null []
 cleanup (hin,hout,herr,ph) = do
  killTree ph
  void (waitForProcess ph)
  forM_ (catMaybes [hin,hout,herr]) $ \h -> hClose h `catch` (\(_::IOException) -> pure ())

validateModelSettingsDraft :: ModelSettingsDraft -> IO ()
validateModelSettingsDraft draft = do
 let choices=modelSettingsDefault draft : M.elems (modelSettingsOverrides draft)
 forM_ (nub (map selectionProvider choices)) $ \provider -> do
  catalog <- case provider of CodexProvider -> codexModels; ClaudeProvider -> claudeModels
  let rows=items catalog "data"
  forM_ (filter ((==provider) . selectionProvider) choices) $ \choice -> do
   model <- maybe (failure 400 "The selected model is not in the current provider catalog.") pure
     (listToMaybe (filter (\row -> at row "model" == selectionModel choice) rows))
   require ((provider == ClaudeProvider && T.null (selectionEffort choice)) || str (selectionEffort choice) `elem` list (get model "efforts")) 400 "The selected effort is not supported by this model."

catalogModel :: Value -> IO Value
catalogModel = parseValue 502 $ withObject "Codex model" $ \o -> do
 model <- o .: "model" :: Parser Text
 label <- o .: "displayName" :: Parser Text
 hidden <- o .: "hidden" :: Parser Bool
 isDefault <- o .: "isDefault" :: Parser Bool
 effort <- o .: "defaultReasoningEffort" :: Parser Text
 options <- o .: "supportedReasoningEfforts" :: Parser [Value]
 efforts <- forM options $ withObject "Reasoning effort" $ \option -> option .: "reasoningEffort" :: Parser Text
 unless (not (T.null model) && not (T.null label) && not (null efforts) && all (not . T.null) efforts && effort `elem` efforts) $ fail "Invalid model or effort choices"
 pure (obj [("model",str model),("displayName",str label),("hidden",Bool hidden),("isDefault",Bool isDefault),("defaultReasoningEffort",str effort),("efforts",toJSON (nub efforts))])

-- Claude's control initialization advertises models without submitting a turn.
claudeModels :: IO Value
claudeModels = do
 result <- timeout 30000000 $ bracket
  (claudeLock Shared >>= maybe (failure 409 "Claude sign-in is changing. Finish or cancel sign-in, then retry model discovery.") pure)
  unlockFile (const discover)
 maybe (failure 504 "Claude model discovery timed out. Try again.") pure result
 where
 discover = do
  binary <- claudeBinary >>= maybe (failure 503 "Claude CLI was not found on this host.") pure
  workdir <- getTemporaryDirectory
  environment <- claudeEnvironment
  let args=["--print","--input-format","stream-json","--output-format","stream-json","--verbose","--safe-mode","--no-session-persistence","--strict-mcp-config","--tools","","--permission-mode","plan"]
  bracket (createProcess (proc binary args) {env=Just environment,cwd=Just workdir,std_in=CreatePipe,std_out=CreatePipe,std_err=CreatePipe,create_group=True,use_process_jobs=True,detach_console=os=="mingw32"}) cleanup $ \handles -> do
   (hin,hout,herr) <- case handles of
    (Just i,Just o,Just e,_) -> pure (i,o,e)
    _ -> failure 502 "Claude discovery could not open its pipes."
   mapM_ (`hSetBinaryMode` True) [hin,hout,herr]
   buffer <- newIORef BS.empty
   let line = do
        bytes <- readIORef buffer
        case BC.elemIndex '\n' bytes of
         Just index -> writeIORef buffer (BS.drop (index+1) bytes) >> pure (BS.take index bytes)
         Nothing -> do
          chunk <- BS.hGetSome hout 8192
          require (not (BS.null chunk)) 502 "Claude closed the model discovery connection."
          require (BS.length bytes + BS.length chunk <= 1048576) 502 "Claude model response is too large."
          writeIORef buffer (bytes <> chunk)
          line
       receive remaining = do
        require (remaining > (0 :: Int)) 502 "Too many Claude discovery notifications."
        value <- line >>= either (const (failure 502 "Claude returned invalid discovery JSON.")) pure . eitherDecodeStrict'
        let response=get value "response"
        if at value "type" /= "control_response" || at response "request_id" /= "sapiens-model-discovery" then receive (remaining-1) else do
         require (at response "subtype" == "success") 502 "Claude could not list models. Check its login and CLI version."
         rows <- field 502 (get response "response") "models" :: IO [Value]
         require (length rows <= 2000) 502 "Claude returned too many models."
         models <- traverse claudeCatalogModel rows
         -- Prefer named entries over the duplicate 'default' alias; keep its flag.
         let defaults=[at row "model" | row <- models,boolean (get row "isDefault")]
             named=sortOn (\row -> boolean (get row "isDefault")) models
             unique=foldl (\acc row -> if any ((==at row "model") . (`at` "model")) acc then acc else acc++[row]) [] named
         pure (obj [("data",arr [put "isDefault" (Bool (at row "model" `elem` defaults)) row | row <- unique])])
       drain = BS.hGetSome herr 8192 >>= \bytes -> unless (BS.null bytes) drain
   withAsync drain $ \_ -> do
    BS.hPut hin (TE.encodeUtf8 (jsonText (obj [("type",str "control_request"),("request_id",str "sapiens-model-discovery"),("request",obj [("subtype",str "initialize")])]) <> "\n"))
    hFlush hin
    receive 1024
 cleanup (hin,hout,herr,ph) = do
  killTree ph
  void (waitForProcess ph)
  forM_ (catMaybes [hin,hout,herr]) $ \h -> hClose h `catch` (\(_::IOException) -> pure ())

claudeCatalogModel :: Value -> IO Value
claudeCatalogModel = parseValue 502 $ withObject "Claude model" $ \o -> do
 alias <- o .: "value" :: Parser Text
 resolved <- o .:? "resolvedModel"
 label <- o .: "displayName" :: Parser Text
 supports <- o .:? "supportsEffort" .!= False
 advertised <- o .:? "supportedEffortLevels" .!= [] :: Parser [Text]
 let model=fromMaybe alias resolved
     efforts=if supports then nub advertised else []
 unless (not (T.null alias) && not (T.null model) && not (T.null label) && all (\effort -> not (T.null effort) && T.length effort <= 80) efforts) $ fail "Invalid Claude model metadata"
 pure (obj [("model",str model),("displayName",str label),("hidden",Bool False),("isDefault",Bool (alias=="default")),("defaultReasoningEffort",str ""),("efforts",toJSON efforts)])

claudeArguments :: ModelConfig -> [String]
claudeArguments config =
 ["--print","--output-format","stream-json","--verbose","--model",T.unpack (configuredModel config),"--no-session-persistence","--dangerously-skip-permissions"]
 ++ [value | not (T.null (configuredEffort config)),value <- ["--effort",T.unpack (configuredEffort config)]]

-- Intermediate assistant text is not completion. Only a successful terminal
-- result can complete the host decision; a zero exit code alone is insufficient.
claudeEvents :: Value -> IO [ProviderEvent]
claudeEvents value = case at value "type" of
 "system" | at value "subtype" == "init" -> (\session -> [SessionStarted session]) <$> field 502 value "session_id"
 "result" -> do
  isError <- field 502 value "is_error" :: IO Bool
  if isError || at value "subtype" /= "success" then pure [ProviderFailed value]
   else (\result -> [AgentMessage result]) <$> field 502 value "result"
 "assistant" | has value "error" && get value "error" /= Null -> pure [ProviderFailed value]
 "assistant" -> pure [ToolStarted (at tool "id") (at tool "name") | tool <- items (get value "message") "content",at tool "type" == "tool_use"]
 "user" -> pure [ToolCompleted (at tool "tool_use_id") "Tool completed" | tool <- items (get value "message") "content",at tool "type" == "tool_result"]
 _ -> pure []

claudeBinary :: IO (Maybe FilePath)
claudeBinary = do
 override <- lookupEnv "SAPIENS_CLAUDE_BINARY"
 case override of
  Just path | not (null path) -> findExecutable path
  _ -> do
   path <- findExecutable "claude"
   home <- getHomeDirectory
   let versions=home </> ".nvm/versions/node"
   exists <- doesDirectoryExist versions
   nodes <- if exists then reverse . sortOn id <$> listDirectory versions else pure []
   let candidates=maybeToList path ++ [home </> ".local/bin" </> (if os=="mingw32" then "claude.exe" else "claude")]
         ++ [versions </> version </> "bin/claude" | version <- nodes,os/="mingw32"]
       native=filter (\file -> os/="mingw32" || map toLower (takeExtension file)==".exe") candidates
   files <- filterM doesFileExist (nub native)
   listToMaybe <$> filterM (fmap executable . getPermissions) files
-- Login and execution deliberately share an app-owned credential/config root.
-- Never inherit a shell's Codex home, API key or workload identity credentials.
codexEnvironment :: IO [(String,String)]
codexEnvironment = do
 home <- codexHome
 environment <- getEnvironment
 binary <- codexBinary
 let name=if os=="mingw32" then map toUpper else id
     tools=maybe "" (\p -> takeDirectory (takeDirectory p)</>"codex-path") binary
     path=fromMaybe "" (listToMaybe [value | (key,value)<-environment,name key=="PATH"])
 pure (("CODEX_HOME",home):("PATH",tools<>[searchPathSeparator]<>path):filter (\(key,_) -> name key/="PATH" && not ("CODEX_" `T.isPrefixOf` T.pack (name key) || "OPENAI_" `T.isPrefixOf` T.pack (name key))) environment)
-- Sapiens' own Claude sign-in lives next to its Codex home. Login, model
-- discovery and runs share it, so signing in or out in Sapiens never touches
-- the user's own Claude CLI login.
claudeHome :: IO FilePath
claudeHome = do
 home <- (</>"claude") . takeDirectory <$> codexHome
 createDirectoryIfMissing True home
#ifndef mingw32_HOST_OS
 setFileMode home 0o700
#endif
 pure home

-- Never inherit a shell's Claude config folder, API key, OAuth token or cloud
-- provider switch: in Claude's credential order they outrank the stored login.
claudeEnvironment :: IO [(String,String)]
claudeEnvironment = do
 home <- claudeHome
 environment <- getEnvironment
 let name=if os=="mingw32" then map toUpper else id
     inherited key = let k=T.pack (name key) in not ("ANTHROPIC_" `T.isPrefixOf` k || "CLAUDE_CODE_" `T.isPrefixOf` k || k=="CLAUDE_CONFIG_DIR")
 pure (("CLAUDE_CONFIG_DIR",home):filter (inherited . fst) environment)

codexHome :: IO FilePath
codexHome = do
 config <- lookupEnv "SAPIENS_CONFIG_DIR" >>= maybe (do
  home <- getHomeDirectory
  base <- if os=="mingw32" then fromMaybe (home</>"AppData/Local") <$> lookupEnv "LOCALAPPDATA" else pure (home</>"Library/Application Support")
  pure (base</>"Sapiens4 Development/config")) pure
 home <- makeAbsolute (config</>"codex")
 createDirectoryIfMissing True home
#ifndef mingw32_HOST_OS
 setFileMode home 0o700
#endif
 pure home
codexConfig :: [String]
codexConfig = ["-c","cli_auth_credentials_store=\"file\"","-c","forced_login_method=\"chatgpt\""]

-- A profile-wide OS lock covers whole runs, including gaps between model calls.
-- Credential changes take the exclusive side, across corpora and host processes.
profileFile :: FilePath -> IO FilePath
profileFile name = (</>name) . takeDirectory <$> codexHome

profileHold :: IO Text
profileHold = do
 path <- profileFile "account-state.json"
 (do
  value <- readJSON path empty
  pure (at value "hold")) `catch` (\(_::IOException) -> pure "uncertain")

holdProfile :: Text -> IO ()
holdProfile hold = profileFile "account-state.json" >>= \path -> writeJSON path (obj [("hold",str hold)])

profileLock :: SharedExclusive -> IO (Maybe FileLock)
profileLock mode = profileFile "account.lock" >>= flip tryLockFile mode

-- Claude runs and discovery hold this lock shared; sign-in and sign-out hold it
-- exclusively. It is separate from the Codex lock.
claudeLock :: SharedExclusive -> IO (Maybe FileLock)
claudeLock mode = profileFile "claude-account.lock" >>= flip tryLockFile mode

claudeNotConnected :: Text
claudeNotConnected = "Claude isn't connected. Connect it in AI Connections, then try again."

-- True only when Claude Code clearly answers that Sapiens' Claude login is
-- signed out (`claude auth status` exits 1). A missing, slow or broken check
-- never blocks work; the run then reports its own error.
claudeSignedOut :: IO Bool
claudeSignedOut = do
 binary <- claudeBinary
 case binary of
  Nothing -> pure False
  Just path -> (do
   environment <- claudeEnvironment
   result <- bracket
    (createProcess (proc path ["auth","status"]) {env=Just environment,std_in=NoStream,std_out=NoStream,std_err=NoStream,create_group=True,use_process_jobs=True,detach_console=os=="mingw32"})
    (\(_,_,_,process) -> killTree process >> void (waitForProcess process))
    (\(_,_,_,process) -> timeout 10000000 (waitForProcess process))
   pure (result==Just (ExitFailure 1))) `catch` (\(_::IOException) -> pure False)

runLease :: IO (Maybe FileLock)
runLease = mask_ $ do
 lease <- profileLock Shared
 case lease of
  Nothing -> pure Nothing
  Just lock -> do
   hold <- profileHold `onException` unlockFile lock
   if T.null hold then pure lease else unlockFile lock >> pure Nothing

withReadyProfile :: IO a -> IO a
withReadyProfile action = bracket
 (runLease >>= maybe (failure 409 "Connect ChatGPT in Settings and resume AI work before starting a task.") pure)
 unlockFile (const action)

codexBinary :: IO (Maybe FilePath)
codexBinary = do
 override <- lookupEnv "SAPIENS_CODEX_BINARY"
 root <- fromMaybe "" <$> lookupEnv "SAPIENS_REPOSITORY"
 packaged <- doesFileExist (root</>"package-manifest.json")
 let payload=root</>if packaged then "codex" else ".build/codex"
     candidate=payload</>"bin"</>if os=="mingw32" then "codex.exe" else "codex"
 case override of
  Just path | not (null path) -> findExecutable path
  _ -> do
   exists <- doesFileExist candidate
   pure (if exists then Just candidate else Nothing)
killTree :: ProcessHandle -> IO ()
killTree ph = do
#ifdef mingw32_HOST_OS
 -- Retain the job handle until termination, even if its root already exited.
 -- getProcessExitCode can otherwise close the root and lose the job handle.
 terminateProcess ph
#else
 result <- getProcessExitCode ph
 when (isNothing result) $ do
  pid <- getPid ph
  case pid of
   Nothing -> terminateProcess ph
   Just root -> do
    let send sig p = signalProcess sig p `catch` (\(_::IOException) -> pure ())
        collect stopped pending = do
         mapM_ (send sigSTOP) pending
         (_,out,_) <- readProcessWithExitCode "ps" ["-axo","pid=,ppid="] ""
         let known = nub (stopped++pending)
             children = nub [child | line <- lines out,[p,pp] <- [words line],Just child <- [readMaybe p],Just parent <- [readMaybe pp],parent `elem` known,child `notElem` known]
         if null children then pure known else collect known children
    stopped <- collect [] [root] `catch` (\(_::SomeException) -> pure [root])
    mapM_ (send sigKILL) (reverse stopped)
  pure ()
#endif
invoke :: Service -> Run -> Text -> IO Text
invoke s run input = do
 foreground <- Computer.captureForeground (repositoryRoot s) (workspaceRoot s (agentIdText (runOwner run)))
 invokeModel s run input `finally` do
  lease <- locked s (readIORef (serviceLease s))
  when (lease==Just (runOwner run,runId run)) $ do
   warning <- Computer.restoreForeground (repositoryRoot s) foreground
   forM_ warning $ \message -> modifyIORef' (runActivity run) (put "warning" (str message))
   locked s $ do
    current <- readIORef (serviceLease s)
    when (current==lease) $ writeIORef (serviceLease s) Nothing
invokeModel :: Service -> Run -> Text -> IO Text
invokeModel s run input = do
 cancelled <- readIORef (runCancel run)
 require (not cancelled) 409 "Stopped by Admin"
 before <- getMonotonicTimeNSec
 require (before < runDeadline run) 504 "Call time limit exhausted between decision nodes"
 let config = runModelConfig run
     provider = configuredProvider config
     workdir = workspaceRoot s (agentIdText (runOwner run))
     args = case provider of CodexProvider -> codexArguments workdir config; ClaudeProvider -> claudeArguments config
 binary <- (case provider of CodexProvider -> codexBinary; ClaudeProvider -> claudeBinary) >>= maybe (failure 503 (providerName provider <> " CLI was not found on this host.")) pure
 environment <- case provider of CodexProvider -> codexEnvironment; ClaudeProvider -> claudeEnvironment
 started <- realToFrac . (*1000) <$> getPOSIXTime :: IO Double
 writeIORef (runActivity run) (obj [("started",toJSON started),("updated",toJSON started),("phase",str "Waiting for model"),("last_action",str "")])
 notifyChange s
 bracket (createProcess (proc binary args) { cwd=Just workdir,env=Just (("SAPIENS_AGENCY_RUN",T.unpack (runIdText (runId run))):filter ((/="SAPIENS_AGENCY_RUN") . fst) environment),std_in=CreatePipe,std_out=CreatePipe,std_err=CreatePipe,create_group=True,use_process_jobs=True,detach_console=os=="mingw32" }) cleanup $ \handles -> do
  (hin,hout,herr,ph) <- case handles of
   (Just inputHandle,Just outputHandle,Just errorHandle,process) -> pure (inputHandle,outputHandle,errorHandle,process)
   _ -> failure 500 "Provider process did not expose its configured pipes"
  modifyMVar_ (runProcess run) (const (pure (Just ph)))
  mapM_ (`hSetBinaryMode` True) [hin,hout,herr]
  stream <- newIORef (ProviderState M.empty Nothing)
  recent <- newIORef []
  errors <- newIORef []
  timedOut <- newIORef False
  let append ref t = modifyIORef' ref (take 20 . (t:))
      consume line = do
       append recent line
       case eitherDecodeStrict' (TE.encodeUtf8 line) of
        Left _ -> pure ()
        Right rawEvent -> do
         events <- case provider of CodexProvider -> (:[]) <$> decodeValue 500 rawEvent; ClaudeProvider -> claudeEvents rawEvent
         forM_ events $ \event -> do
          state <- readIORef stream
          activity <- readIORef (runActivity run)
          time <- realToFrac . (*1000) <$> getPOSIXTime :: IO Double
          (updated,reported) <- validated (providerStep time event state activity)
          writeIORef stream updated
          writeIORef (runActivity run) reported
          when (reported /= activity) (notifyChange s)
      drain h f = let loop = do eof <- hIsEOF h; unless eof (BC.hGetLine h >>= f . TE.decodeUtf8With (\_ _ -> Just '\xfffd') >> loop) in loop
  withAsync ((BS.hPut hin (TE.encodeUtf8 input) `catch` (\(_::IOException) -> pure ())) `finally` hClose hin) $ \writer ->
   withAsync (drain herr (append errors)) $ \stderrReader ->
    withAsync (do
      let deadline=runDeadline run
      let watch = do
           threadDelay 50000
           stop <- readIORef (runCancel run)
           time <- getMonotonicTimeNSec
           if stop || time >= deadline then writeIORef timedOut (not stop) >> killTree ph else watch
      watch) $ \_ -> do
     drain hout consume
     exit <- waitForProcess ph
     void (waitCatch writer)
     void (waitCatch stderrReader)
     stop <- readIORef (runCancel run)
     expired <- readIORef timedOut
     require (not stop) 409 "Stopped by Admin; review external effects before retrying"
     require (not expired) 504 (providerName provider <> " exceeded 1800s; its process tree was stopped.")
     err <- T.unlines . reverse <$> readIORef errors
     out <- T.unlines . reverse <$> readIORef recent
     message <- providerMessage <$> readIORef stream
     -- A failed Claude run caused by a signed-out Claude gets a clear next step.
     when (provider==ClaudeProvider && (exit/=ExitSuccess || isNothing message)) $ do
      signedOut <- claudeSignedOut
      require (not signedOut) 409 claudeNotConnected
     require (exit == ExitSuccess) 500 (providerName provider <> " execution failed: " <> err <> out)
     maybe (failure 500 (providerName provider <> " completed without a successful result.")) pure message
 where cleanup (hin,hout,herr,ph) = do
        killTree ph
        void (waitForProcess ph)
        forM_ (catMaybes [hin,hout,herr]) $ \h -> hClose h `catch` (\(_::IOException) -> pure ())
        modifyMVar_ (runProcess run) (const (pure Nothing))

-- Each provider has its own app-owned account and lock. Nothing leaves the
-- work queued while that provider's sign-in is changing.
modelRunLease :: ModelConfig -> IO (Maybe (IO ()))
modelRunLease config = case configuredProvider config of
 ClaudeProvider -> fmap unlockFile <$> claudeLock Shared
 CodexProvider -> fmap unlockFile <$> runLease

withModelProfile :: Service -> Text -> IO a -> IO a
withModelProfile s owner action = do
 config <- runModelSettings s owner
 case configuredProvider config of
  ClaudeProvider -> bracket
   (claudeLock Shared >>= maybe (failure 409 "Claude sign-in is changing. Finish or cancel it, then try again.") pure)
   unlockFile $ \_ -> do
    signedOut <- claudeSignedOut
    require (not signedOut) 409 claudeNotConnected
    action
  CodexProvider -> withReadyProfile action

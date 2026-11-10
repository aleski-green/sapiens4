{-# LANGUAGE CPP #-}
module Onboarding where

import Types
import qualified Provider as P
import qualified Computer as C
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Data.Aeson (Value(..))
import Data.Char (isAsciiUpper, isDigit)
import Data.IORef
import Data.Maybe
import qualified Data.Text as T
import System.Directory
import System.Exit
import System.FileLock
import System.FilePath
import System.Info
import System.IO
import System.Process hiding (runProcess)
import System.Timeout
import Network.URI (parseURI,uriScheme,uriAuthority,uriRegName,uriUserInfo,uriPort,uriPath)
import qualified Network.Socket as Socket
#ifndef mingw32_HOST_OS
import System.Posix.Signals
#endif

-- Owned by the outer local host only; remote corpus routes cannot reach login.
data Onboarding = Onboarding FilePath (MVar (Bool,Maybe (Async ()))) (IORef Value) (MVar (Bool,[Async T.Text])) (FilePath,MVar Value) ClaudeAuth

-- Claude has its own worker and progress, so a Claude sign-in never blocks or
-- changes Codex, and the other way round.
data ClaudeAuth = ClaudeAuth (MVar (Bool,Maybe (Async ()))) (IORef Value)

openOnboarding :: FilePath -> IO Onboarding
openOnboarding root = do
 home <- P.codexHome
 let path=takeDirectory home</>"onboarding.json"
     initial=obj [("schema",num (1::Int)),("welcomed",Bool False),("completed",Bool False)]
 saved <- readJSON path initial `catch` (\(_::IOException) -> pure initial)
 state <- newMVar (if int (get saved "schema")==1 then saved else initial)
 stored <- doesPathExist (home</>"auth.json")
 hold <- P.profileHold
 when (not stored && T.null hold) (P.holdProfile "disconnected")
 claude <- ClaudeAuth <$> newMVar (False,Nothing) <*> newIORef (claudeLogin "idle" "")
 Onboarding root <$> newMVar (False,Nothing) <*> newIORef (loginState "idle" "") <*> newMVar (False,[]) <*> pure (path,state) <*> pure claude

setupState :: Onboarding -> IO Value
setupState (Onboarding _ _ _ _ (_,state) _) = readMVar state

saveSetup :: Onboarding -> (Value -> Value) -> IO ()
saveSetup (Onboarding _ _ _ _ (path,state) _) update = modifyMVar_ state $ \current -> do
 let next=update current
 writeJSON path next `catch` (\(_::IOException) -> failure 503 "Could not save setup. Check that Sapiens can write to its configuration folder, then retry.")
 pure next

loginState :: T.Text -> T.Text -> Value
loginState state code = loginView state code (if T.null code then "" else "https://auth.openai.com/codex/device")

loginView :: T.Text -> T.Text -> T.Text -> Value
loginView state code url = obj [("state",str state),("code",str code),("url",str url)]

closeOnboarding :: Onboarding -> IO ()
closeOnboarding (Onboarding _ worker _ checks _ (ClaudeAuth claudeWorker _)) = do
 modifyMVar_ checks $ \(_,active) -> mapM_ cancel active >> pure (True,[])
 modifyMVar_ worker $ \(_,active) -> mapM_ cancel active >> pure (True,Nothing)
 modifyMVar_ claudeWorker $ \(_,active) -> mapM_ cancel active >> pure (True,Nothing)

-- HTTP handlers may be abandoned when Warp stops; their subprocesses belong to
-- onboarding, which cancels and joins them before the host can exit.
checkedProviderStatus :: Onboarding -> IO T.Text
checkedProviderStatus onboarding = trackedCheck onboarding providerStatus

trackedCheck :: Onboarding -> IO T.Text -> IO T.Text
trackedCheck (Onboarding _ _ _ checks _ _) runCheck = bracket acquire release wait
 where
 acquire = modifyMVar checks $ \(closed,active) -> do
  require (not closed) 503 "Sapiens is shutting down."
  task <- async runCheck
  pure ((False,task:active),task)
 release task = do
  cancel task
  modifyMVar_ checks $ \(closed,active) -> pure (closed,filter ((/=asyncThreadId task) . asyncThreadId) active)

-- Capture the owned group before waiting can reap the parent. On Windows,
-- process jobs retain descendants until waitForProcess observes the whole job.
withOwnedProcess :: CreateProcess -> ((Maybe Handle,Maybe Handle,Maybe Handle,ProcessHandle) -> IO a) -> IO a
withOwnedProcess command run = bracket acquire release (run . fst)
 where
 acquire = do
  handles@(_,_,_,process) <- createProcess command {create_group=True,use_process_jobs=True,detach_console=os=="mingw32"}
  group <- getPid process
  pure (handles,group)
 release ((input,output,errors,process),group) = do
  P.killTree process
#ifndef mingw32_HOST_OS
  forM_ group $ \pid -> signalProcessGroup sigKILL pid `catch` (\(_::IOException) -> pure ())
#endif
  void (waitForProcess process)
  forM_ [input,output,errors] $ mapM_ (\h -> hClose h `catch` (\(_::IOException) -> pure ()))

-- Exit status is the supported readiness signal. Discard all diagnostics: even
-- login status may print account/API-key information. No model call is made.
providerStatus :: IO T.Text
providerStatus = do
 binary <- P.codexBinary
 case binary of
  Nothing -> pure "missing"
  Just path -> (do
   environment <- P.codexEnvironment
   -- No diagnostic pipes: status output can contain account/key information.
   result <- quietCommand path environment ["login","status"] 10000000
   stored <- maybe (pure False) (doesPathExist . (</>"auth.json")) (lookup "CODEX_HOME" environment)
   pure (case result of Just ExitSuccess -> "signed_in"; Just _ | not stored -> "sign_in_required"; _ -> "unavailable")) `catch` (\(_::IOException) -> pure "unavailable")

onboardingView :: Onboarding -> IO Value
onboardingView onboarding@(Onboarding _ _ progress _ _ _) = do
 login <- readIORef progress
 -- Codex and Claude are checked at the same time, so one slow CLI never doubles the wait.
 (provider,claude) <- concurrently
  (if at login "state" `elem` ["signing_in","signing_out"] then pure (at login "state") else checkedProviderStatus onboarding)
  (claudeView onboarding)
 initial <- setupState onboarding
 -- Reconcile a completed login after success or a restart. Persist before the
 -- UI can close onboarding; a failed write stays a recoverable setup error.
 when (provider=="signed_in" && boolean (get initial "welcomed") && not (boolean (get initial "completed"))) $
  saveSetup onboarding (put "completed" (Bool True))
 saved <- setupState onboarding
 hold <- P.profileHold
 let welcomed=boolean (get saved "welcomed")
     ready=provider=="signed_in"
     complete=welcomed && boolean (get saved "completed")
     step=if not welcomed then "welcome" else if ready then "complete" else "sign_in"
 pure (obj [("schema",num (1::Int)),("step",str step),("completed",Bool complete),("provider",str provider),("login",login),("ready",Bool ready),("hold",str hold),("claude",claude)])

computerView :: Onboarding -> IO Value
computerView (Onboarding root _ _ _ _ _) = do
 binary <- C.blindlyBinary root
 built <- doesFileExist binary
 computer <- if not built then pure "missing" else if os/="darwin" then pure "not_required" else do
  -- Blindly checks AX trust before handling focused. This PID cannot be the
  -- foreground application, so the command never reads window contents.
  result <- (Just <$> C.invoke binary ["focused","--pid","2147483647"] 3) `catches`
   [Handler (\(_::IOException) -> pure Nothing),Handler (\(_::APIError) -> pure Nothing)]
  pure $ case result of
   Just (ExitFailure 77,out,_) -> case at (parseJSONText (T.pack out)) "code" of
    "focus_unavailable" -> "granted"
    "accessibility_permission_denied" -> "denied"
    _ -> "unavailable"
   _ -> "unavailable"
 pure (obj [("computer_permission",str computer),("computer_available",Bool built)])

computerAction :: Onboarding -> Value -> IO Value
computerAction onboarding@(Onboarding root _ _ _ _ _) value = do
 case at value "action" of
  "permission" -> do
   require (os=="darwin") 400 "Accessibility approval is only required on macOS."
   binary <- C.blindlyBinary root
   exists <- doesFileExist binary
   require exists 503 "Computer helper is missing. Reinstall Sapiens to repair it."
   (code,_,_) <- C.invoke binary ["request-permission"] 10
   require (code==ExitSuccess) 503 "Could not request Accessibility access. Open System Settings > Privacy & Security > Accessibility, then try again."
  "refresh" -> pure ()
  _ -> failure 400 "Unknown computer action"
 computerView onboarding

onboardingAction :: Onboarding -> Value -> IO Value
onboardingAction onboarding@(Onboarding _ worker progress _ _ (ClaudeAuth _ claudeProgress)) value = do
 case at value "action" of
  "begin" -> saveSetup onboarding (put "welcomed" (Bool True))
  "defer" -> modifyMVar_ worker $ \(closed,active) -> do
   login <- readIORef progress
   require (at login "state" `notElem` ["signing_in","signing_out"]) 409 "Finish or cancel sign-in first."
   saveSetup onboarding (put "completed" (Bool True) . put "welcomed" (Bool True))
   pure (closed,active)
  "connect" -> do
   saveSetup onboarding (put "welcomed" (Bool True))
   startAuth onboarding "connect"
  "choose" -> do
   login <- readIORef progress
   require (at login "state" `notElem` ["signing_in","signing_out"]) 409 "Cancel sign-in first."
   saved <- setupState onboarding
   require (not (boolean (get saved "completed"))) 409 "Setup is already complete."
   saveSetup onboarding (put "welcomed" (Bool False))
  "finish" -> do
   saved <- setupState onboarding
   require (boolean (get saved "welcomed")) 409 "Start setup from the welcome screen."
   status <- checkedProviderStatus onboarding
   require (status=="signed_in") 409 "Sign in to Codex before entering your workspace."
   saveSetup onboarding (put "completed" (Bool True))
  action | action `elem` ["login","device-login","change-account","sign-out"] -> startAuth onboarding action
  "resume" -> bracket
   (P.profileLock Exclusive >>= maybe (failure 409 "AI work or sign-in is still running. Try again when it finishes.") pure)
   unlockFile $ \_ -> do
    status <- checkedProviderStatus onboarding
    require (status=="signed_in") 409 "Connect ChatGPT before resuming AI work."
    hold <- P.profileHold
    require (hold=="review") 409 "Finish connecting your ChatGPT account first."
    P.holdProfile ""
  "open-login" -> do
   login <- readIORef progress
   require (at login "state"=="signing_in" && not (T.null (at login "url"))) 409 "Start sign-in first."
   openLoginURL (at login "url")
  "cancel" -> modifyMVar_ worker $ \(closed,active) -> do
   current <- readIORef progress
   require (at current "state" `elem` ["signing_in","complete"]) 409 "Sign-out cannot be cancelled once it has started."
   mapM_ cancel active
   status <- checkedProviderStatus onboarding
   saved <- setupState onboarding
   when (status=="signed_in") $ bracket (P.profileLock Exclusive) (mapM_ unlockFile) $ mapM_ $ \_ ->
    P.holdProfile (if boolean (get saved "completed") then "review" else "")
   writeIORef progress (loginState (if status=="signed_in" then "complete" else "cancelled") "")
   pure (closed,Nothing)
  "refresh" -> pure ()
  "claude-connect" -> startClaudeAuth onboarding False
  "claude-sign-out" -> startClaudeAuth onboarding True
  "claude-cancel" -> cancelClaudeAuth onboarding
  "claude-open-login" -> do
   login <- readIORef claudeProgress
   require (at login "state"=="signing_in" && validClaudeLoginURL (at login "url")) 409 "The Claude sign-in link is no longer available. Start again."
   openBrowser (at login "url")
  _ -> failure 400 "Unknown setup action"
 onboardingView onboarding

-- Serialize all mutations with the UI worker and take an OS-wide exclusive
-- lease before touching credentials. A running task is never stopped by logout.
startAuth :: Onboarding -> T.Text -> IO ()
startAuth onboarding@(Onboarding _ worker progress _ _ _) action = modifyMVar_ worker $ \(closed,active) -> do
 require (not closed) 503 "Sapiens is shutting down."
 running <- maybe (pure False) (fmap isNothing . poll) active
 require (not running) 409 "Account sign-in or sign-out is already running."
 saved <- setupState onboarding
 let replacing=action `elem` ["change-account","sign-out"]
 binary <- P.codexBinary >>= maybe (failure 503 "Codex is missing. Reinstall Sapiens to repair its runtime.") pure
 environment <- P.codexEnvironment
 bracketOnError
  (P.profileLock Exclusive >>= maybe (failure 409 "Finish running tasks before changing your ChatGPT account. Another sign-in may also be in progress.") pure)
  unlockFile $ \lease -> do
   status <- checkedProviderStatus onboarding
   if action=="connect" && status=="signed_in" then unlockFile lease >> pure (False,Nothing)
   else do
    if replacing then require (status `elem` ["signed_in","unavailable"]) 409 "ChatGPT is already disconnected."
    else do
     require (status/="signed_in") 409 "ChatGPT is already connected."
     require (status=="sign_in_required") 503 "Could not check your existing sign-in. Recheck before continuing."
    -- Explicit account actions can start from Settings without the welcome UI.
    saveSetup onboarding (put "welcomed" (Bool True))
    -- Persist the hold before revocation or login can begin. A crash cannot
    -- release queued work under an uncertain or newly selected account.
    P.holdProfile (if replacing then "uncertain" else "disconnected")
    writeIORef progress (loginState (if replacing then "signing_out" else "signing_in") "")
    task <- async $ flip finally (unlockFile lease) $
     authFlow binary environment saved `catch` (\(errorValue::SomeException) -> case fromException errorValue :: Maybe SomeAsyncException of
      Just _ -> throwIO errorValue
      Nothing -> writeIORef progress (loginState "failed" ""))
    pure (False,Just task)
 where
 authFlow binary environment saved = do
  removed <- if action `elem` ["change-account","sign-out"] then do
   result <- quietCommand binary environment ["logout"] 30000000
   status <- providerStatus
   let removed=result==Just ExitSuccess && status=="sign_in_required"
   when removed (P.holdProfile "disconnected")
   pure removed
   else pure True
  if not removed then writeIORef progress (loginState "logout_failed" "")
  else if action=="sign-out" then writeIORef progress (loginState "signed_out" "")
  else do
   writeIORef progress (loginState "signing_in" "")
   outcome <- signIn binary environment progress (action=="device-login")
   status <- providerStatus
   if status=="signed_in" then do
    P.holdProfile (if boolean (get saved "completed") then "review" else "")
    writeIORef progress (loginState "complete" "")
   else writeIORef progress (loginState (if outcome=="complete" then "failed" else outcome) "")

quietCommand :: FilePath -> [(String,String)] -> [String] -> Int -> IO (Maybe ExitCode)
quietCommand binary environment args duration = withOwnedProcess
 (proc binary (P.codexConfig ++ args)) {env=Just environment,std_in=NoStream,std_out=NoStream,std_err=NoStream}
 (\(_,_,_,process) -> timeout duration (waitForProcess process))

-- Only the official HTTPS authorization URL is exposed, never CLI diagnostics.
validLoginURL :: T.Text -> Bool
validLoginURL url = T.length url<=16384 && case parseURI (T.unpack url) of
 Just uri -> uriScheme uri=="https:" && uriPath uri=="/oauth/authorize" && case uriAuthority uri of
  Just authority -> uriRegName authority=="auth.openai.com" && null (uriUserInfo authority) && null (uriPort authority)
  Nothing -> False
 Nothing -> False

openLoginURL :: T.Text -> IO ()
openLoginURL url = do
 require (validLoginURL url || url=="https://auth.openai.com/codex/device") 409 "The sign-in link is no longer available. Start again."
 openBrowser url

-- Callers validate the link first; only official sign-in pages are opened.
openBrowser :: T.Text -> IO ()
openBrowser url = do
 let (program,args)=if os=="darwin" then ("/usr/bin/open",[T.unpack url]) else if os=="mingw32" then ("rundll32.exe",["url.dll,FileProtocolHandler",T.unpack url]) else ("xdg-open",[T.unpack url])
 (code,_,_) <- C.invoke program args 10
 require (code==ExitSuccess) 503 "Could not open your browser. Copy the sign-in link and open it in your browser."

-- Codex's browser listener can cancel an existing listener on its fixed port.
-- Refuse an occupied port before invoking it; never probe /cancel ourselves.
browserPortAvailable :: IO Bool
browserPortAvailable = Socket.withSocketsDo $
 (bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \socket -> do
   -- Match the CLI listener: a recently closed callback may still have
   -- TIME_WAIT connections. Only an active listener should block a new login.
   Socket.setSocketOption socket Socket.ReuseAddr 1
   Socket.bind socket (Socket.SockAddrInet 1455 (Socket.tupleToHostAddress (127,0,0,1)))
   Socket.listen socket 1
   pure True) `catch` (\(_::IOException) -> pure False)

signIn :: FilePath -> [(String,String)] -> IORef Value -> Bool -> IO T.Text
signIn binary environment progress device = do
 available <- if device then pure True else browserPortAvailable
 if not available then pure "browser_busy" else withOwnedProcess
  (proc binary (P.codexConfig ++ ["login"] ++ ["--device-auth" | device]))
   {env=Just environment,std_in=NoStream,std_out=if device then CreatePipe else NoStream,std_err=if device then NoStream else CreatePipe}
  (\(_,output,errors,process) -> do
   handle <- maybe (failure 500 "Sign-in output unavailable") pure (if device then output else errors)
   let consume expecting = do
        ended <- hIsEOF handle
        unless ended $ do
         line <- T.strip . T.pack . stripANSI <$> hGetLine handle
         if device then
          when (expecting && T.length line>=6 && T.length line<=20 && T.all (\c -> isAsciiUpper c || isDigit c || c=='-') line) $
           writeIORef progress (loginState "signing_in" line)
         else when (validLoginURL line) $ writeIORef progress (loginView "signing_in" "" line)
         consume ("Enter this one-time code" `T.isInfixOf` line)
   result <- timeout (16*60*1000000) (consume False >> waitForProcess process)
   pure (case result of Just ExitSuccess -> "complete"; Nothing -> "expired"; _ -> "failed"))

stripANSI :: String -> String
stripANSI [] = []
stripANSI ('\ESC':'[':rest) = stripANSI (drop 1 (dropWhile (\c -> c<'@' || c>'~') rest))
stripANSI (c:rest) = c:stripANSI rest

-- Claude sign-in uses Sapiens' own Claude folder (P.claudeEnvironment).

claudeLogin :: T.Text -> T.Text -> Value
claudeLogin state url = obj [("state",str state),("url",str url)]

claudeView :: Onboarding -> IO Value
claudeView onboarding@(Onboarding _ _ _ _ _ (ClaudeAuth _ progress)) = do
 login <- readIORef progress
 status <- if at login "state" `elem` ["signing_in","signing_out"] then pure (at login "state") else trackedCheck onboarding claudeStatus
 pure (obj [("status",str status),("login",login)])

-- The exit code of `claude auth status` is the signal: 0 signed in, 1 signed
-- out. Its output is discarded because it contains the account email.
claudeStatus :: IO T.Text
claudeStatus = do
 binary <- P.claudeBinary
 case binary of
  Nothing -> pure "missing"
  Just path -> (do
   environment <- P.claudeEnvironment
   result <- quietClaude path environment ["auth","status"] 10000000
   pure (case result of
    Just ExitSuccess -> "signed_in"
    Just (ExitFailure 1) -> "sign_in_required"
    _ -> "unavailable")) `catch` (\(_::IOException) -> pure "unavailable")

quietClaude :: FilePath -> [(String,String)] -> [String] -> Int -> IO (Maybe ExitCode)
quietClaude binary environment args duration = withOwnedProcess
 (proc binary args) {env=Just environment,std_in=NoStream,std_out=NoStream,std_err=NoStream}
 (\(_,_,_,process) -> timeout duration (waitForProcess process))

-- One Claude account change at a time, under the exclusive Claude lock, so the
-- account never changes under a running Claude task. Codex is not affected.
startClaudeAuth :: Onboarding -> Bool -> IO ()
startClaudeAuth onboarding@(Onboarding _ _ _ _ _ (ClaudeAuth worker progress)) signOut = modifyMVar_ worker $ \(closed,active) -> do
 require (not closed) 503 "Sapiens is shutting down."
 running <- maybe (pure False) (fmap isNothing . poll) active
 require (not running) 409 "Claude sign-in or sign-out is already running."
 binary <- P.claudeBinary >>= maybe (failure 503 "Claude Code isn't installed on this computer. Install it, then try again.") pure
 environment <- P.claudeEnvironment
 bracketOnError
  (P.claudeLock Exclusive >>= maybe (failure 409 "Finish running Claude tasks before changing your Claude account.") pure)
  unlockFile $ \lease -> do
   status <- trackedCheck onboarding claudeStatus
   if signOut then require (status `elem` ["signed_in","unavailable"]) 409 "Claude is already disconnected."
   else do
    require (status/="signed_in") 409 "Claude is already connected."
    require (status=="sign_in_required") 503 "Could not check your Claude sign-in. Check again before continuing."
   writeIORef progress (claudeLogin (if signOut then "signing_out" else "signing_in") "")
   task <- async $ flip finally (unlockFile lease) $
    flow binary environment `catch` (\(errorValue::SomeException) -> case fromException errorValue :: Maybe SomeAsyncException of
     Just _ -> throwIO errorValue
     Nothing -> writeIORef progress (claudeLogin "failed" ""))
   pure (False,Just task)
 where
 flow binary environment
  | signOut = do
   result <- quietClaude binary environment ["auth","logout"] 30000000
   status <- claudeStatus
   writeIORef progress (claudeLogin (if result==Just ExitSuccess && status=="sign_in_required" then "signed_out" else "logout_failed") "")
  | otherwise = do
   outcome <- claudeSignIn binary environment progress
   status <- claudeStatus
   writeIORef progress (claudeLogin (if status=="signed_in" then "complete" else if outcome=="complete" then "failed" else outcome) "")

-- Only a sign-in that is still waiting for the browser can be cancelled.
-- Cancelling stops the Claude process tree and releases the Claude lock.
cancelClaudeAuth :: Onboarding -> IO ()
cancelClaudeAuth onboarding@(Onboarding _ _ _ _ _ (ClaudeAuth worker progress)) = modifyMVar_ worker $ \(closed,active) -> do
 current <- readIORef progress
 require (at current "state"=="signing_in") 409 "Only a Claude sign-in that is waiting for the browser can be cancelled."
 mapM_ cancel active
 status <- trackedCheck onboarding claudeStatus
 writeIORef progress (claudeLogin (if status=="signed_in" then "complete" else "cancelled") "")
 pure (closed,Nothing)

-- `claude auth login` opens the browser and exits once the user approves. Only
-- the official link is kept, for "Open sign-in page". Stdin is closed because
-- nothing is typed; both output streams share one pipe.
claudeSignIn :: FilePath -> [(String,String)] -> IORef Value -> IO T.Text
claudeSignIn binary environment progress = bracket createPipe (\(reader,writer) -> hClose writer >> hClose reader) $ \(reader,writer) ->
 withOwnedProcess
  (proc binary ["auth","login"]) {env=Just environment,std_in=CreatePipe,std_out=UseHandle writer,std_err=UseHandle writer}
  (\(input,_,_,process) -> do
   hClose writer
   mapM_ (\h -> hClose h `catch` (\(_::IOException) -> pure ())) input
   encoding <- mkTextEncoding "UTF-8//ROUNDTRIP"
   hSetEncoding reader encoding
   let consume = do
        ended <- hIsEOF reader
        unless ended $ do
         line <- T.strip . T.pack . stripANSI <$> hGetLine reader
         let signInLink = T.strip (snd (T.breakOnEnd "visit:" line))
         when ("visit:" `T.isInfixOf` line && validClaudeLoginURL signInLink) $ writeIORef progress (claudeLogin "signing_in" signInLink)
         consume
   result <- timeout (16*60*1000000) (consume >> waitForProcess process)
   pure (case result of Just ExitSuccess -> "complete"; Nothing -> "expired"; _ -> "failed"))

-- Only the official HTTPS authorization pages are shown or opened.
validClaudeLoginURL :: T.Text -> Bool
validClaudeLoginURL url = T.length url<=16384 && case parseURI (T.unpack url) of
 Just uri -> uriScheme uri=="https:" && case uriAuthority uri of
  Just authority -> null (uriUserInfo authority) && null (uriPort authority)
   && uriRegName authority=="claude.com" && uriPath uri=="/cai/oauth/authorize"
  Nothing -> False
 Nothing -> False

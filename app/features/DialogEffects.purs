module Sapiens.DialogEffects where

import Web.Event.Event as Event
import Sapiens.Form as F
import Prelude
import Control.Promise (Promise, toAffE)
import Data.Argonaut.Core (Json, toString)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, try, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error, message)
import Effect.Ref as Ref
import Foreign.Object as O
import Halogen as H
import Libs4.Browser as B
import Sapiens.Action as Intent
import Sapiens.Action (Action(..), Success(..))
import Sapiens.Connections as C
import Sapiens.Data as D
import Sapiens.Browser as Browser
import Sapiens.Domain as X
import Sapiens.Dialog as Dialog
import Sapiens.Effects as E
import Sapiens.Model as M
import Sapiens.Navigation as N
import Sapiens.Remote as R

foreign import afterRender :: Effect (Promise Unit)

setupPath :: M.Dialog -> String
setupPath d = if d.kind == M.Computer then "/api/host/computer" else "/api/host/onboarding"

-- | Keep polling while Codex or Claude is signing in or out.
accountChanging :: Json -> Boolean
accountChanging value = A.elem (D.s "provider" value) changing || A.elem (D.s "status" (D.get "claude" value)) changing
  where changing = ["signing_in","signing_out"]

handle :: C.Runtime -> E.Dispatch -> Action -> E.UI Unit
handle runtime dispatch action = case action of
  OpenDialog kind record -> do
    m <- H.get
    if kind == M.ConnectRemote && m.installRequired then dispatch Install else do
      when (m.dialog /= Nothing) $ void $ H.fork $ H.liftAff $ C.cancelPairing runtime
      let d = Dialog.make kind record m
      H.modify_ $ Dialog.open d
      when (kind == M.ConnectRemote && M.remote m) $ liftEffect $ B.historyPush $ D.json {dialog: true}
      E.sync runtime
      case kind of
        M.Models -> loadModels F.Codex m d *> loadModels F.Claude m d *> loadModelSettings m d
        M.Computer | m.snapshot.computer.platform == "linux" -> receive d.identity (\value -> E.modifyDialog d.identity _ {content=F.computerAccess value,status=M.Editing}) $ E.api runtime m "/api/computer" "GET" D.null
        M.DecisionPrompts -> receive d.identity (\value -> E.modifyDialog d.identity _ {content=F.Prompts $ map F.prompt $ D.rows "prompts" value,fields=F.decode $ D.first $ D.rows "prompts" value,status=M.Editing}) $ E.api runtime m "/api/decision-prompts" "GET" D.null
        M.RelayList -> receive d.identity (\value -> E.modifyDialog d.identity _ {content=F.relayRegistry value,status=M.Editing}) $ C.json "/api/host/relays" "GET" D.null
        M.Onboarding -> dispatch $ OnboardingPoll d.identity
        M.AIProviders -> when m.localAvailable $ dispatch $ OnboardingPoll d.identity
        M.Computer -> when m.localAvailable $ dispatch $ OnboardingPoll d.identity
        M.HostPairing -> dispatch $ HostPairPoll d.identity
        M.EditCorpora -> liftEffect $ B.focus "#corpora-dialog textarea"
        M.ConnectRemote -> liftEffect $ B.focus "#paste-invitation textarea"
        _ -> pure unit
  ModelPickerKey event picker index labels -> do
    key <- Browser.key <$> liftEffect (B.eventData event)
    m <- H.get
    traverse_ (\d -> case d.content of
      F.ModelPreview draft | not (M.dialogBusy d) -> do
        let count = A.length labels
            open = draft.picker == picker
            letter = if CU.length key.key == 1 && key.key /= " " then S.toLower key.key else ""
            order = A.drop (index+1) labels <> A.take (index+1) labels
            matched = if letter == "" then Nothing else A.findIndex (S.startsWith (S.Pattern letter) <<< S.toLower) order
            target = case key.key of
              "ArrowDown" -> Just $ if index < 0 then 0 else mod (index+1) (max 1 count)
              "ArrowUp" -> Just $ if index < 0 then count-1 else mod (index-1+count) (max 1 count)
              "Home" -> Just 0
              "End" -> Just $ count-1
              _ -> map (\offset -> mod (index+1+offset) (max 1 count)) matched
        if key.key == "Escape" && open then do
          liftEffect $ Event.preventDefault event *> Event.stopPropagation event
          E.modifyDialog d.identity _ {content=F.ModelPreview $ draft {picker=""}}
          liftEffect $ B.focus $ "#" <> picker
        else if key.key == "Tab" && open then do
          E.modifyDialog d.identity _ {content=F.ModelPreview $ draft {picker=""}}
          liftEffect $ B.focus $ "#" <> picker
        else unless (key.ctrl || key.meta || key.composing) $ traverse_ (\next -> when (count > 0) do
          liftEffect $ Event.preventDefault event *> Event.stopPropagation event
          E.modifyDialog d.identity _ {content=F.ModelPreview $ draft {picker=picker}}
          liftEffect $ B.focus $ "#" <> picker <> "-option-" <> show next) target
      _ -> pure unit) m.dialog
  OnboardingPoll id -> E.inDialog id \d -> when (A.elem d.kind [M.Onboarding,M.AIProviders,M.Computer] && not (M.dialogBusy d)) do
    receive id (\value -> do
      let signedIn = D.s "provider" value == "signed_in" && case d.content of
            F.Setup previous -> D.s "provider" previous == "signing_in"
            _ -> false
      when signedIn $ liftEffect $ B.nativeMessage $ D.json {activate: true}
      when (d.kind /= M.Computer) $ H.modify_ _ {account=value}
      E.modifyDialog id \current ->
        let page = if d.kind == M.AIProviders && (current.providerPage == M.CodexAuth || D.s "hold" value == "review" && current.providerPage == M.Providers) && D.s "provider" value == "signed_in" then M.CodexDetails else current.providerPage
        in current {content=F.Setup value,status=M.Editing,providerPage=page}
      when (d.kind == M.AIProviders && d.providerPage == M.CodexAuth && D.s "provider" value == "signed_in") $ focusSetup id "#resume-ai-work"
      when (D.s "provider" value == "signing_in" && (case d.content of
        F.Setup previous -> D.s "provider" previous /= "signing_in"
        _ -> true)) $ focusSetup id "#cancel-codex-login"
      when (d.kind == M.Onboarding && D.b "completed" value) $ dispatch CloseDialog
      when (accountChanging value) $ E.later 1000.0 $ dispatch $ OnboardingPoll id) $ C.json (setupPath d) "GET" D.null
  CloseDialog -> do
    m <- H.get
    case m.dialog of
      Just d | not (Dialog.dismissible d) -> E.modifyDialog d.identity $ M.setDialogError "Finish or cancel sign-in before leaving. Signing out cannot be cancelled. You can quit the app and recover later."
      Just d | d.kind == M.AIProviders && maybe false (\previous -> previous.kind == M.Models) (A.last m.dialogStack) -> do
        H.modify_ Dialog.back
        E.sync runtime
        current <- H.get
        traverse_ (\previous -> loadModels F.Codex current previous *> loadModels F.Claude current previous) current.dialog
      _ -> do
        void $ H.fork $ H.liftAff $ C.cancelPairing runtime
        H.modify_ Dialog.close
        E.sync runtime
  ProviderNavigate page -> do
    m <- H.get
    traverse_ (\d -> when (d.kind == M.AIProviders && not (M.dialogBusy d) && (not (Dialog.authenticating d) || page == M.CodexAuth)) do
      E.modifyDialog d.identity _ {providerPage=page}
      when (page == M.CodexAuth) $ focusSetup d.identity "#cancel-codex-login") m.dialog
  Field key value -> do
    H.modify_ \m -> m {dialog=map (\d -> if d.kind == M.AIProviders && M.dialogBusy d then d else Dialog.updateField key value d) m.dialog}
    when (key == F.ShowLink) do
      liftEffect $ B.focus "#host-pair-link"
      m <- H.get
      traverse_ (\d -> liftEffect $ B.selectRange "#host-pair-link" 0 $ CU.length $ d.fields.link) m.dialog
  CheckField value checked -> H.modify_ \m -> m {dialog=map (\d -> d {fields=F.member value checked d.fields}) m.dialog}
  SubmitDialog -> do
    m <- H.get
    traverse_ (\d -> unless (M.dialogBusy d) $ submit m d) m.dialog
  AttachmentKind kind -> do
    m <- H.get
    if A.elem kind [X.LinkAttachment,X.FileAttachment] then dispatch $ OpenDialog (M.Reference kind) F.NoRecord else do
      unless (M.firstMessageFull m) do
        H.modify_ _ {uploading=m.uploading+1,dialog=map (M.setDialogError "") m.dialog}
        attach m do
          selected <- B.chooseFile (if kind == X.ImageAttachment then "image/png,image/jpeg,image/gif,image/webp" else ".pdf,.txt,.md,.csv,.json,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.rtf,.odt") 10485760
          case selected of
            Nothing -> pure Nothing
            Just file -> Just <$> E.api runtime m (M.ownerPath m <> "/attachments") "POST" (D.json {kind, name: file.name, data: file.data})
      when (M.firstMessageFull m) $ E.notify "Attach up to 8 items per message."
  DialogCommand command -> commandAction command
  _ -> pure unit
  where
  -- Let rendering finish, then recheck the dialog generation before focusing.
  focusSetup id target = void $ H.fork do
    H.liftAff $ toAffE afterRender
    E.inDialog id \_ -> liftEffect $ B.focus target
  attach m operation = E.attempt operation \result -> E.inEpoch m.epoch \current -> do
    H.modify_ _ {uploading=max 0 $ current.uploading-1}
    traverse_ (\d -> E.modifyDialog d.identity (M.setDialogBusy false)) m.dialog
    case result of
      Left failure -> case m.dialog, current.dialog of
        Just requested, Just active | requested.identity == active.identity ->
          E.modifyDialog requested.identity $ M.setDialogError $ message failure
        _, _ -> E.notify $ message failure
      Right selected -> traverse_ (\item -> do
        H.modify_ \s -> s {attachments=O.alter (Just <<< flip A.snoc (X.attachment item) <<< fromMaybe []) m.selected s.attachments}
        dispatch CloseDialog
        E.save dispatch) selected
  receive :: forall a. Int -> (a -> E.UI Unit) -> Aff a -> E.UI Unit
  receive id done operation = E.attempt operation \result -> E.inDialog id \_ -> do
    E.modifyDialog id (M.setDialogBusy false)
    case result of
      Left failure -> E.modifyDialog id (M.setDialogError $ message failure)
      Right value -> done value
  runDialog :: forall a. M.Dialog -> (a -> E.UI Unit) -> Aff a -> E.UI Unit
  runDialog d done operation = do
    E.modifyDialog d.identity _ {status=M.Submitting ""}
    receive d.identity done operation
  loadModelSettings m d = runDialog d (acceptModelSettings d.identity) $ E.api runtime m "/api/model-settings" "GET" D.null
  acceptModelSettings identity value = E.modifyDialog identity \current -> case current.content of
    F.ModelPreview draft -> current {content=F.ModelPreview $ F.savedModelDraft value draft,status=M.Editing}
    _ -> current
  loadModels provider m d = do
    let setCatalog catalog current = case current.content of
          F.ModelPreview draft -> current {content=F.ModelPreview $ if provider == F.Codex then draft {catalog=catalog} else draft {claudeCatalog=catalog}}
          _ -> current
    E.modifyDialog d.identity (setCatalog F.CatalogLoading)
    E.attempt (E.api runtime m (if provider == F.Codex then "/api/providers/codex/models" else "/api/providers/claude/models") "GET" D.null) \result -> E.inEpoch m.epoch \_ ->
      E.modifyDialog d.identity $ setCatalog $ case result of
        Left failure -> F.CatalogFailed (message failure)
        Right value -> F.modelCatalog value
  saved caption _ = dispatch CloseDialog *> E.notify caption *> dispatch Poll
  submit m d = case d.kind of
    kind | kind == M.AgentSettings || kind == M.GroupSettings -> case Dialog.saveEntity d of
      Left failure -> E.modifyDialog d.identity $ M.setDialogError failure
      Right request -> runSave m d request
    M.GroupTask -> saveTask m d false
    M.Reference kind -> if M.firstMessageFull m then E.modifyDialog d.identity (M.setDialogError $ "Attach up to 8 items per message.") else do
      H.modify_ _ {uploading=m.uploading+1}
      E.modifyDialog d.identity (M.setDialogBusy true)
      attach m $ Just <$> E.api runtime m (M.ownerPath m <> "/attachments") "POST" (D.json {kind, value: D.json d.fields.value})
    M.DecisionPrompts -> dispatch $ Mutate ("/api/decision-prompts/" <> B.encodeURI (d.fields.node)) "PUT" (D.json {content: D.json d.fields.content}) (SavedPrompt $ d.fields.content)
    M.CreateCorpora -> do
      E.modifyDialog d.identity _ {status=M.Submitting ""}
      E.attempt (C.json "/api/host/local" "POST" (D.json {name:d.fields.name,scope:d.fields.scope})) \result -> do
        current <- H.get
        case result of
          Left failure -> E.modifyDialog d.identity _ {status=M.Rejected $ message failure}
          Right value -> do
            let record = (X.corpora value) {key=D.s "id" value}
            H.modify_ \s -> s {records=A.snoc s.records record}
            when ((_.identity <$> current.dialog) == Just d.identity) $ dispatch CloseDialog
            dispatch $ EnterCorpora $ record.key
    M.EditCorpora -> runDialog d (\_ -> dispatch CloseDialog *> dispatch LoadRegistry) do
      C.reconcile runtime (M.remote m) m.records m.active
      info <- C.request runtime (M.remote m) (F.contextCorpora d.record) "/api/corpora" "GET" D.null
      when (D.s "status" info == "archived") $ throwError $ error "Restore this archived corpora before sending. Your draft is kept here."
      current <- if D.s "status" info == "paused" then C.lifecycle runtime (M.remote m) (F.contextCorpora d.record) "activate" else pure info
      C.request runtime (M.remote m) (F.contextCorpora d.record) ("/api/agents/" <> B.encodeURI (D.s "chief_id" current) <> "/messages") "POST" $ D.json {text: D.json d.fields.message}
    M.RelayAdd -> case parseRelay $ d.fields.connection of
      Left failure -> E.modifyDialog d.identity (M.setDialogError $ failure)
      Right connection -> do
        let change = D.obj $ [Tuple "action" (D.text "save"),Tuple "name" (D.text $ S.trim $ d.fields.name),Tuple "connection" connection] <> if F.contextId d.record == "" then [] else [Tuple "id" $ D.json $ F.contextId d.record]
        if F.contextId d.record == (F.relays d.content).selected && F.contextConnection d.record /= connection then confirmRelay d change (d.fields.name) else changeRelay d change
    _ -> pure unit
  runSave m d request = runDialog d (saved request.caption) $ E.api runtime m request.path request.method request.body
  saveTask m d deleted = runDialog d (saved request.caption) $ E.api runtime m request.path request.method request.body
    where
    request = Dialog.saveTask m d deleted
  push kind record = do
    m <- H.get
    let next = Dialog.make kind record m
    H.modify_ $ Dialog.push next
    E.sync runtime
  relayList content = do
    m <- H.get
    let previous = A.find (( _ == M.RelayList) <<< _.kind) m.dialogStack
        record = maybe F.NoRecord _.record previous
        next = Dialog.make M.RelayList record m
    H.modify_ _ {dialog=Just $ next {content=F.relayRegistry content},dialogStack=[],sequence=next.identity}
    E.sync runtime
  changeRelay d data_ = runDialog d (\value -> when (D.b "reset" value) (resetRelay true) *> relayList value) $ C.json "/api/host/relays" "POST" $ D.put "revision" (D.json (F.relays d.content).revision) data_
  confirmRelay d change to = do
    let current = fromMaybe (F.relay D.empty) $ A.find ((_ == (F.relays d.content).selected) <<< _.id) (F.relays d.content).servers
    push M.RelaySwitch $ F.ChangeRecord {change,saving:D.s "action" change == "save",from:current.name,to}
  resetRelay broadcast = do
    m <- H.get
    liftEffect do
      clients <- Ref.read runtime.clients
      traverse_ R.close $ O.values clients
      Ref.write O.empty runtime.clients
      Ref.write O.empty runtime.credentials
      Ref.write Nothing runtime.persistedSnapshot
      traverse_ (\r -> B.storageRemove $ "s4.snapshot." <> r.key) $ A.filter (( _ == X.Remote) <<< _.location) m.records
    let locals = map (_ {paired=false}) $ A.filter (( _ == X.Local) <<< _.location) m.records
        active = if (M.activeRecord m).location == X.Remote then fromMaybe "" $ _.key <$> A.head locals else m.active
    H.modify_ _ {records=locals,active=active,connection=M.Offline,epoch=m.epoch+1,polling=false,saving=false,nativeReporting=false,nativeReports=[],snapshotContent=Nothing,documents=O.empty}
    void $ liftEffect $ C.write "s4.records" $ D.json locals
    void $ liftEffect $ C.write "s4.active" $ D.text active
    void $ liftEffect $ C.write "s4.lifecycle.pending" D.null
    void $ liftEffect $ C.write "s4.switch.pending" D.null
    when broadcast do
      uuid <- liftEffect B.uuid
      void $ liftEffect $ C.write "s4.relay-reset" $ D.text uuid
    dispatch LoadRegistry
  commandAction command = do
    m <- H.get
    case command of
      Intent.CreateAgent -> do
        dispatch $ SetScope N.All
        current <- H.get
        let template = m.snapshot.creation_template
        when (S.trim (M.draft current) == "") $ dispatch $ Draft template
        liftEffect $ B.focus "#message-input"
        latest <- H.get
        case CU.indexOf (S.Pattern "WORKFLOW") $ M.draft latest of
          Just index -> liftEffect $ B.selectRange "#message-input" index (index+8)
          Nothing -> pure unit
      Intent.MentionGroup entity -> case m.groupView of
        Nothing -> dispatch $ Select entity.id
        Just group -> do
          dispatch $ Select group
          current <- H.get
          let old = M.draft current
              prefix = A.find (\name -> S.take (CU.length name) old == name) $ map (\id -> "@" <> (M.agent current id).name <> " ") $ (M.selected current).members
          dispatch $ Draft $ "@" <> entity.name <> " " <> maybe old (\p -> CU.drop (CU.length p) old) prefix
          liftEffect $ B.focus "#message-input"
      Intent.ResetRelay -> resetRelay false
      Intent.InstallPrompt -> void $ H.fork $ void $ H.liftAff $ try $ toAffE B.installPrompt
      _ -> traverse_ (\d -> unless (M.dialogBusy d) $ dialogCommand m d command) m.dialog
  dialogCommand m d command = case command of
    Intent.ManageModelConnections -> when (d.kind == M.Models && not (M.dialogBusy d) && not (M.remote m) && (M.activeRecord m).location == X.Local) do
      let next = Dialog.make M.AIProviders F.NoRecord m
      H.modify_ \current -> (Dialog.push next current) {dialog=Just next}
      E.sync runtime
      dispatch $ OnboardingPoll next.identity
    Intent.ToggleModelPicker picker index -> case d.content of
      F.ModelPreview draft -> do
        let opening = draft.picker /= picker
        E.modifyDialog d.identity _ {content=F.ModelPreview $ draft {picker=if opening then picker else ""}}
        liftEffect $ B.focus $ "#" <> picker <> if opening then "-option-" <> show index else ""
      _ -> pure unit
    Intent.PickModelOption picker edit -> case d.content of
      F.ModelPreview draft -> do
        E.modifyDialog d.identity _ {content=F.ModelPreview $ F.updateModelPreview edit draft}
        liftEffect $ B.focus $ "#" <> picker
      _ -> pure unit
    Intent.ReloadModelSettings -> when (d.kind == M.Models) $ loadModelSettings m d
    Intent.SaveModelSettings -> case d.kind, d.content of
      M.Models, F.ModelPreview draft | F.modelDraftValid draft && F.modelDraftChanged draft ->
        runDialog d (saved "Model settings saved.") $ E.api runtime m "/api/model-settings" "PUT" (F.modelDraftPayload draft)
      _, _ -> pure unit
    Intent.ReloadModels provider -> case d.kind, d.content of
      M.Models, F.ModelPreview draft | F.providerCatalog provider draft /= F.CatalogLoading -> loadModels provider m d
      _, _ -> pure unit
    Intent.PreviewModel edit -> case d.kind, d.content of
      M.Models, F.ModelPreview draft -> E.modifyDialog d.identity _ {content=F.ModelPreview $ F.updateModelPreview edit draft}
      _, _ -> pure unit
    Intent.Setup setupAction -> do
      -- A mutation owns a new dialog generation: old polling responses and
      -- timers cannot overwrite its result or unlock its busy controls.
      let requested = d {identity=m.sequence+1}
      H.modify_ _ {dialog=Just requested,sequence=requested.identity}
      runDialog requested (\value -> do
        when (requested.kind /= M.Computer) $ H.modify_ _ {account=value}
        E.modifyDialog requested.identity \current ->
          let page = if requested.kind /= M.AIProviders then M.Providers
                else if A.elem setupAction ["login","device-login","change-account"] then
                  if D.s "provider" value == "signed_in" then M.CodexDetails else M.CodexAuth
                else if setupAction == "cancel" then M.CodexDetails
                else if A.elem setupAction ["sign-out","claude-sign-out"] then M.Providers
                else current.providerPage
          in current {content=F.Setup value,status=M.Editing,providerPage=page}
        focusSetup requested.identity (if D.s "provider" value == "signing_in" then "#cancel-codex-login" else "#dialog-title")
        when (requested.kind == M.Onboarding && D.b "completed" value) $ dispatch CloseDialog
        when (accountChanging value) $ E.later 1000.0 $ dispatch $ OnboardingPoll requested.identity) $ C.json (setupPath requested) "POST" $ D.json {action: setupAction}
    Intent.SuggestNames -> do
      E.modifyDialog d.identity (\s -> s {identity=s.identity+1})
      H.modify_ (\s -> s {sequence=s.sequence+1})
    Intent.DeleteTask -> saveTask m d true
    Intent.AddRelay -> push M.RelayAdd F.NoRecord
    Intent.BackRelay -> if A.null m.dialogStack then dispatch CloseDialog else H.modify_ Dialog.back *> E.sync runtime
    Intent.SelectRelay relay -> when (relay.id /= (F.relays d.content).selected) $ confirmRelay d (D.json {action: "switch", id: relay.id}) relay.name
    Intent.ConfirmRelay -> changeRelay d $ D.put "confirm_revoke" (D.bool true) $ (F.contextChange d.record).change
    Intent.EditRelay id -> runDialog d (push M.RelayAdd <<< F.relayContext) $ C.json ("/api/host/relays/" <> B.encodeURI id) "GET" D.null
    Intent.ArchiveRelay relay -> changeRelay d $ D.json {action: if relay.archived then "restore" else "archive", id: relay.id}
    Intent.ImportRelay -> runDialog d (traverse_ (\raw -> E.modifyDialog d.identity \current -> current {fields=current.fields {connection=raw},status=M.Editing})) do
      selected <- B.chooseFile "application/json,.json" 4096
      case selected of
        Nothing -> pure Nothing
        Just file -> case toString (B.base64Decode file.data) of
          Nothing -> throwError $ error "Could not decode the connection file."
          Just raw -> case parseRelay raw of
            Left failure -> throwError $ error failure
            Right _ -> pure $ Just raw
    Intent.DoneRelay -> do
      let current = fromMaybe (F.relay D.empty) $ A.find ((_ == (F.relays d.content).selected) <<< _.id) (F.relays d.content).servers
      if (F.contextCorpora d.record).key == "" then dispatch CloseDialog else if current.beta && not ((F.relays d.content).beta_accepted) then push M.RelayTerms d.record else dispatch $ OpenDialog M.HostPairing $ F.readyContext d.record
    Intent.AcceptRelay -> do
      E.modifyDialog d.identity (M.setDialogBusy true)
      receive d.identity (\_ -> dispatch $ OpenDialog M.HostPairing $ F.readyContext d.record) $
        C.json "/api/host/relays" "POST" $ D.json {revision: D.json (F.relays d.content).revision, action: "accept-beta", accepted: true}
    Intent.HostPair intent -> do
      let revoking = intent == Intent.RevokeHost || intent == Intent.ReplaceHost
      proceed <- if revoking then liftEffect $ B.confirm $ if intent == Intent.RevokeHost then "Revoke this remote access? It will need to pair again." else "Replace the trusted remote device? The previous device will lose access." else pure true
      when proceed $ runDialog d (\result -> do
        E.modifyDialog d.identity $ M.setDialogError $ if D.valid (D.get "relay_deleted" result) && not (D.b "relay_deleted" result) then "Revoked locally. Relay could not be reached." else ""
        dispatch $ HostPairPoll d.identity) do
        previous <- if revoking then C.request runtime (M.remote m) (F.contextCorpora d.record) "/api/remote/revoke" "POST" D.empty else pure D.empty
        case intent of
          Intent.InviteHost -> invite m d
          Intent.ReplaceHost -> invite m d
          Intent.ApproveHost peer -> C.request runtime (M.remote m) (F.contextCorpora d.record) "/api/remote/approve" "POST" $ D.json {peer}
          Intent.RevokeHost -> pure previous
    _ -> pure unit

  invite m d = C.request runtime (M.remote m) (F.contextCorpora d.record) "/api/remote/pair" "POST" (D.json {saved:true})

parseRelay :: String -> Either String Json
parseRelay raw =
  let value = D.parse raw
      url = Browser.url "about:blank" $ D.s "relay" value
      valid = CU.length raw <= 4096 && D.s "format" value == "sapiens-relay-connection-v1" && url.username == "" && url.password == "" && url.search == "" && url.hash == "" && url.path == "/" && (url.protocol == "https:" || url.protocol == "http:" && A.elem (url.host) ["localhost","127.0.0.1","[::1]"])
      base = D.json {format: D.get "format" value, relay: D.json url.origin}
  in if not valid then Left "Enter valid relay connection JSON." else if D.b "beta" value && D.s "token" value == "" then Right $ D.put "beta" (D.bool true) base else if D.matches "^[\\x21-\\x7e]{32,256}$" $ D.s "token" value then Right $ D.put "token" (D.get "token" value) base else Left "Enter valid relay connection JSON."

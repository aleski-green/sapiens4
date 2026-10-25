module Sapiens.DialogEffects where

import Prelude
import Control.Promise (toAffE)
import Data.Argonaut.Core (Json)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as S
import Data.String.CodeUnits as CU
import Data.Tuple (Tuple(..))
import Effect.Aff (try, throwError)
import Effect.Class (liftEffect)
import Effect.Exception (error, message)
import Effect.Ref as Ref
import Foreign.Object as O
import Halogen as H
import Libs4.Browser as B
import Sapiens.Action (Action(..), Success(..), DialogResult(..))
import Sapiens.Connections as C
import Sapiens.Data as D
import Sapiens.Dialog as Dialog
import Sapiens.Effects as E
import Sapiens.Model as M
import Sapiens.Navigation as N
import Sapiens.Remote as R

handle :: C.Runtime -> E.Dispatch -> Action -> E.UI Unit
handle runtime dispatch action = case action of
  OpenDialog kind record -> do
    m <- H.get
    if kind == M.ConnectRemote && m.installRequired then dispatch Install else do
      when (m.dialog /= Nothing) $ void $ H.fork $ H.liftAff $ C.cancelPairing runtime
      let d = Dialog.make kind record m
      H.modify_ _ {dialog=Just d,dialogStack=[],menu=Nothing,sequence=d.identity,mention=Nothing}
      when (kind == M.ConnectRemote && M.remote m) $ liftEffect $ B.historyPush $ D.obj [Tuple "dialog" $ D.bool true]
      E.sync
      case kind of
        M.DecisionPrompts -> E.run (DialogReceived d.identity PromptsLoaded) (E.api runtime m "/api/decision-prompts" "GET" D.null) dispatch
        M.RelayList -> E.run (DialogReceived d.identity RelaysLoaded) (C.json "/api/host/relays" "GET" D.null) dispatch
        M.HostPairing -> dispatch $ HostPairPoll d.identity
        M.EditCorpora -> liftEffect $ B.focus "#corpora-dialog textarea"
        M.ConnectRemote -> liftEffect $ B.focus "#paste-invitation textarea"
        _ -> pure unit
  CloseDialog -> do
    void $ H.fork $ H.liftAff $ C.cancelPairing runtime
    H.modify_ _ {dialog=Nothing,dialogStack=[]}
    E.sync
  Field key value -> do
    H.modify_ \m -> m {dialog=map (updateField key value) m.dialog}
    when (key == "showLink") do
      liftEffect $ B.focus "#host-pair-link"
      m <- H.get
      traverse_ (\d -> liftEffect $ B.selectRange "#host-pair-link" 0 $ CU.length $ D.s "link" d.fields) m.dialog
  CheckField key value checked -> H.modify_ \m -> m {dialog=map (\d -> d {fields=D.put key (D.array $ map D.text $ if checked then A.nub $ A.snoc (D.strings $ D.get key d.fields) value else A.filter (_ /= value) $ D.strings $ D.get key d.fields) d.fields}) m.dialog}
  SubmitDialog -> do
    m <- H.get
    traverse_ (\d -> unless d.busy $ submit m d) m.dialog
  DialogReceived id resultType result -> do
    m <- H.get
    when ((_.identity <$> m.dialog) == Just id) do
      modifyDialog id _ {busy=false}
      case result of
        Left failure -> modifyDialog id _ {error=message failure}
        Right value -> case resultType of
          PromptsLoaded -> do
            let first = D.first $ D.rows "prompts" value
            modifyDialog id _ {content=value,fields=first,error=""}
          RelaysLoaded -> modifyDialog id _ {content=value,error=""}
          RelayEditLoaded -> push M.RelayAdd value
          RelayImported -> modifyDialog id \d -> d {fields=D.put "connection" (D.get "raw" value) d.fields,error=""}
          RelaySaved -> do
            when (D.b "reset" value) $ resetRelay true
            relayList value
          DialogSaved caption -> dispatch CloseDialog *> E.notify dispatch caption *> dispatch Poll
          CorporaEdited -> dispatch CloseDialog *> dispatch LoadRegistry
          PairingStatus -> do
            modifyDialog id _ {error=if D.valid (D.get "relay_deleted" value) && not (D.b "relay_deleted" value) then "Revoked locally. Relay could not be reached." else ""}
            dispatch $ HostPairPoll id
  AttachmentKind kind -> do
    m <- H.get
    if kind == "link" || kind == "filepath" then dispatch $ OpenDialog (M.Reference kind) (D.obj [Tuple "owner" $ D.text m.selected]) else do
      unless (A.length (M.attachments m) >= 8) do
        H.modify_ _ {uploading=m.uploading+1}
        E.run (AttachmentReceived m.epoch m.selected) (do
          file <- toAffE $ B.chooseFile (if kind == "image" then "image/png,image/jpeg,image/gif,image/webp" else ".pdf,.txt,.md,.csv,.json,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.rtf,.odt") 10485760
          if not (D.valid file) then pure D.null else E.api runtime m (M.ownerPath m <> "/attachments") "POST" (D.obj [Tuple "kind" (D.text kind),Tuple "name" $ D.get "name" file,Tuple "data" $ D.get "data" file])) dispatch
      when (A.length (M.attachments m) >= 8) $ E.notify dispatch "Attach up to 8 items per message."
  DialogCommand command value -> commandAction command value
  _ -> pure unit
  where
  modifyDialog id f = H.modify_ \m -> m {dialog=map (\d -> if d.identity == id then f d else d) m.dialog}
  updateField key value d =
    let fields = if key == "node" && d.kind == M.DecisionPrompts then fromMaybe d.fields $ A.find (( _ == value) <<< D.s "node") $ D.rows "prompts" d.content else D.put key (D.text value) d.fields
        withLead = if key == "lead" && d.kind == M.GroupSettings then D.put "members" (D.array $ map D.text $ A.nub $ A.snoc (D.strings $ D.get "members" fields) value) fields else fields
    in d {fields=withLead,error=""}
  runDialog _ d result operation = do
    modifyDialog d.identity _ {busy=true,error=""}
    E.run (DialogReceived d.identity result) operation dispatch
  submit m d = case d.kind of
    M.AgentSettings -> if not (D.matches "^[A-Z][A-Za-z0-9_.:#+|()&$^\\-]*$" $ D.s "name" d.fields) then modifyDialog d.identity _ {error=Dialog.nameHelp} else
      runDialog m d (DialogSaved "Sapi saved.") $ E.api runtime m ("/api/agents/" <> B.encodeURI (D.s "id" d.record)) "PUT" $ D.obj [Tuple "name" $ D.get "name" d.fields,Tuple "role" $ D.get "role" d.fields,Tuple "manager" $ if D.s "manager" d.fields == "" then D.null else D.get "manager" d.fields,Tuple "execution" $ D.obj [Tuple "mode" $ D.get "mode" d.fields]]
    M.GroupSettings -> runDialog m d (DialogSaved "Group saved.") $ E.api runtime m ("/api/groups/" <> B.encodeURI (D.s "id" d.record)) "PUT" $ D.obj $ map (\key -> Tuple key $ D.get key d.fields) ["name","description","lead","members","revision"]
    M.GroupTask -> saveTask m d false
    M.Reference kind -> if A.length (M.attachments m) >= 8 then modifyDialog d.identity _ {error="Attach up to 8 items per message."} else do
      H.modify_ _ {uploading=m.uploading+1}
      modifyDialog d.identity _ {busy=true}
      E.run (AttachmentReceived m.epoch m.selected) (E.api runtime m (M.ownerPath m <> "/attachments") "POST" $ D.obj [Tuple "kind" (D.text kind),Tuple "value" $ D.get "value" d.fields]) dispatch
    M.DecisionPrompts -> dispatch $ Mutate ("/api/decision-prompts/" <> B.encodeURI (D.s "node" d.fields)) "PUT" (D.obj [Tuple "content" $ D.get "content" d.fields]) (SavedPrompt $ D.s "content" d.fields)
    M.CreateCorpora -> do
      modifyDialog d.identity _ {busy=true,error=""}
      void $ H.fork do
        result <- H.liftAff $ try $ C.json "/api/host/local" "POST" d.fields
        current <- H.get
        case result of
          Left failure -> modifyDialog d.identity _ {busy=false,error=message failure}
          Right value -> do
            let record = D.put "key" (D.get "id" value) value
            H.modify_ \s -> s {records=A.snoc s.records record}
            when ((_.identity <$> current.dialog) == Just d.identity) $ dispatch CloseDialog
            dispatch $ EnterCorpora $ D.s "key" record
    M.EditCorpora -> runDialog m d CorporaEdited do
      C.reconcile runtime (M.remote m) m.records m.active
      info <- C.request runtime (M.remote m) d.record "/api/corpora" "GET" D.null
      when (D.s "status" info == "archived") $ throwError $ error "Restore this archived corpora before sending. Your draft is kept here."
      current <- if D.s "status" info == "paused" then C.lifecycle runtime (M.remote m) d.record "activate" else pure info
      C.request runtime (M.remote m) d.record ("/api/agents/" <> B.encodeURI (D.s "chief_id" current) <> "/messages") "POST" $ D.obj [Tuple "text" $ D.get "message" d.fields]
    M.RelayAdd -> case parseRelay $ D.s "connection" d.fields of
      Left failure -> modifyDialog d.identity _ {error=failure}
      Right connection -> do
        let change = D.obj $ [Tuple "action" (D.text "save"),Tuple "name" (D.text $ S.trim $ D.s "name" d.fields),Tuple "connection" connection] <> if D.s "id" d.record == "" then [] else [Tuple "id" $ D.get "id" d.record]
        if D.s "id" d.record == D.s "selected" d.content && D.get "connection" d.record /= connection then confirmRelay d change (D.s "name" d.fields) else changeRelay m d change
    _ -> pure unit
  saveTask m d deleted =
    let existing = D.s "id" d.record /= ""
        data_ = D.merge d.fields $ if existing then D.obj [Tuple "revision" (D.get "revision" d.record),Tuple "deleted" (D.bool deleted),Tuple "state" (if D.b "deleted" d.record then D.text "backlog" else D.get "state" d.fields)] else D.empty
    in runDialog m d (DialogSaved $ if deleted then "Task deleted." else "Task saved.") $ E.api runtime m (M.ownerPath m <> "/tasks" <> if existing then "/" <> B.encodeURI (D.s "id" d.record) else "") (if existing then "PUT" else "POST") data_
  push kind record = do
    m <- H.get
    let next = Dialog.make kind record m
        content = fromMaybe D.null $ _.content <$> m.dialog
    H.modify_ _ {dialog=Just $ next {content=content},dialogStack=m.dialogStack <> fromMaybe [] (map A.singleton m.dialog),sequence=next.identity}
    E.sync
  relayList content = do
    m <- H.get
    let previous = A.find (( _ == M.RelayList) <<< _.kind) m.dialogStack
        record = maybe D.empty _.record previous
        next = Dialog.make M.RelayList record m
    H.modify_ _ {dialog=Just $ next {content=content},dialogStack=[],sequence=next.identity}
    E.sync
  changeRelay m d data_ = runDialog m d RelaySaved $ C.json "/api/host/relays" "POST" $ D.put "revision" (D.get "revision" d.content) data_
  confirmRelay d change to = do
    let current = D.find (D.s "selected" d.content) $ D.rows "servers" d.content
    push M.RelaySwitch $ D.obj [Tuple "change" change,Tuple "from" $ D.get "name" current,Tuple "to" $ D.text to]
  resetRelay broadcast = do
    m <- H.get
    liftEffect do
      clients <- Ref.read runtime.clients
      traverse_ R.close $ O.values clients
      Ref.write O.empty runtime.clients
      Ref.write O.empty runtime.credentials
      traverse_ (\r -> B.storageRemove $ "s4.snapshot." <> D.s "key" r) $ A.filter (( _ == "Remote") <<< D.s "location") m.records
    let locals = map (D.put "paired" $ D.bool false) $ A.filter (( _ == "Local") <<< D.s "location") m.records
        active = if D.s "location" (M.activeRecord m) == "Remote" then D.s "key" $ D.first locals else m.active
    H.modify_ _ {records=locals,active=active,online=false,epoch=m.epoch+1,polling=false,saving=false,nativeReporting=false,nativeReports=[]}
    void $ liftEffect $ C.write "s4.records" $ D.array locals
    void $ liftEffect $ C.write "s4.active" $ D.text active
    void $ liftEffect $ C.write "s4.lifecycle.pending" D.null
    void $ liftEffect $ C.write "s4.switch.pending" D.null
    when broadcast do
      uuid <- liftEffect B.uuid
      void $ liftEffect $ C.write "s4.relay-reset" $ D.text uuid
    dispatch LoadRegistry
  commandAction command value = do
    m <- H.get
    case command of
      "create-agent" -> do
        dispatch $ SetScope N.All
        current <- H.get
        let template = D.s "creation_template" m.snapshot
        when (S.trim (M.draft current) == "") $ dispatch $ Draft template
        liftEffect $ B.focus "#message-input"
        latest <- H.get
        case CU.indexOf (S.Pattern "WORKFLOW") $ M.draft latest of
          Just index -> liftEffect $ B.selectRange "#message-input" index (index+8)
          Nothing -> pure unit
      "group-mention" -> case m.groupView of
        Nothing -> dispatch $ Select $ D.s "id" value
        Just group -> do
          dispatch $ Select group
          current <- H.get
          let old = M.draft current
              prefix = A.find (\name -> S.take (CU.length name) old == name) $ map (\id -> "@" <> D.s "name" (M.agent current id) <> " ") $ D.strings $ D.get "members" $ M.selected current
          dispatch $ Draft $ "@" <> D.s "name" value <> " " <> maybe old (\p -> CU.drop (CU.length p) old) prefix
          liftEffect $ B.focus "#message-input"
      "relay-reset" -> resetRelay false
      "install-prompt" -> void $ H.fork $ void $ H.liftAff $ try $ toAffE B.installPrompt
      "replace-draft" -> do
        dispatch CloseDialog
        dispatch $ Draft $ D.s "text" value
      _ -> traverse_ (\d -> unless d.busy $ dialogCommand m d command value) m.dialog
  dialogCommand m d command value = case command of
    "names" -> do
      modifyDialog d.identity (\s -> s {identity=s.identity+1})
      H.modify_ (\s -> s {sequence=s.sequence+1})
    "delete-task" -> saveTask m d true
    "relay-add" -> push M.RelayAdd D.empty
    "relay-back" -> case A.unsnoc m.dialogStack of
      Just {init,last} -> do
        let next = last {identity=m.sequence+1}
        H.modify_ _ {dialog=Just next,dialogStack=init,sequence=next.identity}
        E.sync
      Nothing -> dispatch CloseDialog
    "relay-select" -> when (D.s "id" value /= D.s "selected" d.content) $ confirmRelay d (D.obj [Tuple "action" (D.text "switch"),Tuple "id" $ D.get "id" value]) (D.s "name" value)
    "relay-confirm" -> changeRelay m d $ D.put "confirm_revoke" (D.bool true) $ D.get "change" d.record
    "relay-edit" -> runDialog m d RelayEditLoaded $ C.json ("/api/host/relays/" <> B.encodeURI (D.s "id" value)) "GET" D.null
    "relay-archive" -> changeRelay m d $ D.obj [Tuple "action" (D.text $ if D.b "archived" value then "restore" else "archive"),Tuple "id" $ D.get "id" value]
    "relay-import" -> runDialog m d RelayImported do
      file <- toAffE $ B.chooseFile "application/json,.json" 4096
      if not (D.valid file) then pure (D.obj [Tuple "raw" $ D.get "connection" d.fields]) else do
        let raw = D.str $ B.base64Decode $ D.s "data" file
        case parseRelay raw of
          Left failure -> throwError $ error failure
          Right _ -> pure $ D.obj [Tuple "raw" $ D.text raw]
    "relay-done" -> do
      let current = D.find (D.s "selected" d.content) $ D.rows "servers" d.content
      if D.s "key" d.record == "" then dispatch CloseDialog else if D.b "beta" current && not (D.b "beta_accepted" d.content) then push M.RelayTerms d.record else dispatch $ OpenDialog M.HostPairing $ D.put "_ready" (D.bool true) d.record
    "relay-accept" -> do
      modifyDialog d.identity _ {busy=true}
      void $ H.fork do
        result <- H.liftAff $ try $ C.json "/api/host/relays" "POST" $ D.obj [Tuple "revision" (D.get "revision" d.content),Tuple "action" (D.text "accept-beta"),Tuple "accepted" (D.bool true)]
        current <- H.get
        when ((_.identity <$> current.dialog) == Just d.identity) $ case result of
          Left failure -> modifyDialog d.identity _ {busy=false,error=message failure}
          Right _ -> dispatch $ OpenDialog M.HostPairing $ D.put "_ready" (D.bool true) d.record
    _ | S.take 5 command == "host-" -> do
      let op = S.drop 5 command
      proceed <- if op == "revoke" || op == "replace" then liftEffect $ B.confirm $ if op == "revoke" then "Revoke this remote access? It will need to pair again." else "Replace the trusted remote device? The previous device will lose access." else pure true
      when proceed $ runDialog m d PairingStatus do
        previous <- if op == "revoke" || op == "replace" then C.request runtime (M.remote m) d.record "/api/remote/revoke" "POST" D.empty else pure D.empty
        if op == "pair" || op == "replace" then C.request runtime (M.remote m) d.record "/api/remote/pair" "POST" (D.obj [Tuple "saved" $ D.bool true]) else if op == "approve" then C.request runtime (M.remote m) d.record "/api/remote/approve" "POST" (D.obj [Tuple "peer" $ D.get "peer" value]) else pure previous
    _ -> pure unit

parseRelay :: String -> Either String Json
parseRelay raw =
  let value = D.parse raw
      url = B.parseURL "about:blank" $ D.s "relay" value
      valid = CU.length raw <= 4096 && D.s "format" value == "sapiens-relay-connection-v1" && D.s "username" url == "" && D.s "password" url == "" && D.s "search" url == "" && D.s "hash" url == "" && D.s "path" url == "/" && (D.s "protocol" url == "https:" || D.s "protocol" url == "http:" && A.elem (D.s "host" url) ["localhost","127.0.0.1","[::1]"])
      base = D.obj [Tuple "format" $ D.get "format" value,Tuple "relay" $ D.get "origin" url]
  in if not valid then Left "Enter valid relay connection JSON." else if D.b "beta" value && D.s "token" value == "" then Right $ D.put "beta" (D.bool true) base else if D.matches "^[\\x21-\\x7e]{32,256}$" $ D.s "token" value then Right $ D.put "token" (D.get "token" value) base else Left "Enter valid relay connection JSON."

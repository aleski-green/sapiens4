module Sapiens.Action where

import Data.Maybe (Maybe)
import Data.Argonaut.Core (Json)
import Data.Either (Either)
import Effect.Exception (Error)
import Sapiens.Connections (Registry)
import Sapiens.Model (DialogKind)
import Sapiens.Navigation (Activity, Scope, Pane, Period)
import Web.Event.Event (Event)

data Action
  = Initialize
  | LoadRegistry
  | Finalize
  | Poll
  | RegistryReceived Int (Either Error Registry)
  | SnapshotReceived Int String (Either Error Json)
  | Select String
  | SetScope Scope
  | Navigate Activity
  | DefaultWork
  | SetPeriod Period
  | Search String
  | ToggleSearch
  | TogglePane Pane
  | Home
  | Draft String
  | MessageKey Event
  | Send
  | MessageFinished Int String String (Array Json) (Either Error Json)
  | RetryDocument String
  | ToggleExpanded String
  | Clarify Json
  | Menu String
  | CloseMenu
  | OpenDialog DialogKind Json
  | CloseDialog
  | Field String String
  | CheckField String String Boolean
  | SubmitDialog
  | DialogReceived Int DialogResult (Either Error Json)
  | DialogCommand String Json
  | Copy String String
  | Scroll
  | UserScroll
  | Resize
  | Global String Json
  | GlobalEvent String Event
  | DrainNative
  | NativeReceived Int String String (Either Error Json)
  | NativeReport Json
  | MentionChoice Int
  | MentionCursor
  | RefreshTheme
  | Theme
  | Persist
  | PreferencesReceived Int String (Either Error Json)
  | EnterCorpora String
  | Lifecycle String
  | LifecycleReceived Int (Either Error Json)
  | ShowArchived Boolean
  | Mutate String String Json Success
  | MutationReceived Int (Maybe Int) Success (Either Error Json)
  | AttachmentKind String
  | AttachmentReceived Int String (Either Error Json)
  | RemoveAttachment String
  | Browser String Json
  | BrowserReceived Int String String (Either Error Json)
  | Address String
  | OpenAddress
  | EditAddress
  | OpenFile
  | PrepareDraft String String
  | Feedback
  | Pair
  | PairCode Int String String
  | PairReceived Int (Either Error Json)
  | ScanQR
  | ScanFrame Int
  | UploadQR
  | QRReceived Int (Either Error Json)
  | StopScan
  | HostPairPoll Int
  | HostPairReceived Int (Either Error Json)
  | QRImageReceived Int String (Either Error String)
  | Install
  | Submit Event Action
  | Link Event Action
  | OpenLink String
  | NoteAnchor String

data Success = Refresh | CloseAndRefresh String | SavedPrompt String

data DialogResult = PromptsLoaded | RelayEditLoaded | RelayImported | RelaysLoaded | RelaySaved | DialogSaved String | CorporaEdited | PairingStatus

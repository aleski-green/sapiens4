module Sapiens.Components (main, install, mountTasks) where

import Prelude hiding (append, join)
import Data.Array as A
import Data.Foldable (for_)
import Effect (Effect)
import Sapiens.Activity as Activity
import Sapiens.Composer as Composer
import Sapiens.Conversation as Conversation
import Sapiens.Groups as Groups
import Sapiens.Mentions as Mentions
import Sapiens.Names as Names
import Sapiens.Notes as Notes
import Sapiens.Panes as Panes
import Sapiens.Session as Session
import Sapiens.Shell as Shell
import Sapiens.Tasks as Tasks
import Sapiens.Work as Work
import Sapiens.Workspace as Workspace
import Sapiens.Runtime

mountTasks :: Effect Unit
mountTasks = do
  Tasks.main
  write "clarificationWorkload" null
  let effect action = callback $ const action
      stateField name = read "state" <#> flip get name
  api_ <- call (global .! "window" .! "SapiensTasks") "mount" [value
    { selected:effect $ stateField "selected", panel:effect $ stateField "panel"
    , workView:effect $ read "workView", period:effect $ read "taskPeriod"
    , workloads:effect $ read "live" <#> \live -> live .! "workloads" <||> value ([] :: Array Value)
    , agentName:callback \args -> exec "agent" args <#> flip get "name"
    , formatText:callback $ exec "formatText", displayTime:callback $ exec "displayTime", toast:callback $ exec "toast"
    , fetchTasks:callback $ exec "api"
    , appendMessage:callback \args -> do
        state <- read "state"
        let id = string $ at 0 args
        setField (state .! "messages") id $ A.snoc (items id $ state .! "messages") (at 1 args)
        pure null
    , ensureMessages:callback \args -> do
        state <- read "state"
        let id = string $ at 0 args
        unless (boolean $ state .! "messages" .! id) $ setField (state .! "messages") id ([] :: Array Value)
        pure null
    , openChat:callback $ exec "openChat", clarify:callback \args -> write "clarificationWorkload" (at 0 args) $> null
    , prompts:effect $ exec "api" [value "/api/decision-prompts"]
    , savePrompt:callback \args -> do
        encoded <- call global "encodeURIComponent" [at 0 args]
        exec "api" [value $ "/api/decision-prompts/" <> string encoded, value "PUT", value {content:at 1 args}]
    , modal:callback \args -> exec "modal" [at 0 args, at 1 args, value "CORPORA"] }]
  for_ ["taskRow", "renderTasks", "delegationMessages", "taskCallControls", "editDecisionPrompts"] \name -> write name $ api_ .! name
  register "taskElement" \args -> element (string $ at 0 args) (string $ at 1 args) (string $ at 2 args)

install :: Effect Unit
install = do
  Panes.main
  Shell.main
  Session.main
  Activity.main
  Groups.main
  Work.main
  Names.main
  Mentions.main
  Notes.main
  Workspace.main
  Conversation.main
  Composer.main
  mountTasks

-- Component factories are also used by browser hosts embedding a workspace.
-- They expose application behavior, while the RSpec driver owns assertions.
main :: Effect Unit
main = do
  let installer action = callback \_ -> action $> null
  setField global "SapiensComponents"
    {shell:installer Shell.main, panes:installer Panes.main, activity:installer Activity.main
    , groups:installer Groups.main, work:installer Work.main, names:installer Names.main
    , mentions:installer Mentions.main, notes:installer Notes.main, workspace:installer Workspace.main
    , conversation:installer Conversation.main, session:installer Session.main, composer:installer Composer.main
    , tasks:installer mountTasks, install:installer install, mountShell:installer Shell.mount
    , mountActivity:installer $ fire "mountActivity" [], mountWork:installer $ fire "mountWork" [], mountGroups:installer $ fire "mountGroups" []
    , mountWorkspace:installer $ fire "mountWorkspace" [], mountMentions:installer $ fire "mountMentions" [], mountConversation:installer $ fire "mountConversation" []}

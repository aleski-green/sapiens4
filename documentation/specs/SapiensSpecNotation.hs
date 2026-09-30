{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE EmptyDataDecls #-}

-- Sapiens Haskell Notation Spec
-- Status: working specification
--
-- Sapiens = project / system
-- Sapi    = persistent autonomous agent (Sapi and agent are synonyms)
-- Agency = a harnessed LLM definition/constructor
-- SapiHarness = Agency + Context + Contract
-- AgencyRun = the execution record produced by running a SapiHarness
--
-- Revised 2026-09-30: Agency/Memo terminology and explicit execution runs.
-- Revised 2026-10-01: flat organization; Groups cannot contain subgroups.
-- Revised 2026-10-01: SapiHarness is structure; AgencyRun is its execution result.
--
-- Haskell is used as compact formal notation.
-- The semantics are authoritative; implementation details may evolve.

module SapiensSpecNotation where

import Data.List.NonEmpty (NonEmpty)


-- =============================================================
-- 1. rTernarity
-- =============================================================
--
-- Prefer three meaningful child responsibilities at an architectural split.
-- Apply recursively when subdivision is useful.
--
-- Never invent artificial branches only to reach three.
-- Domain semantics take precedence.
--
-- Natural examples:
--
-- Actor
-- +-- Admin
-- +-- Sapi
-- \-- System
--
-- SapiPosition
-- +-- Chief
-- +-- Leader
-- \-- Member
--
-- SapiHarness
-- +-- Agency
-- +-- Context
-- \-- Contract


-- Constructor naming:
-- when a constructor would otherwise duplicate its type name,
-- use Mk<Type>, e.g. Sapi = MkSapi, Group = MkGroup.
--
-- =============================================================
-- 2. Actors
-- =============================================================

-- Anything that can own, initiate, or be assigned work.
--
-- Admin and System are singletons.
-- Sapi carries the identity of the specific Sapi.
data Actor
  = Admin
  | Sapi SapiId
  | System


-- Haskell cardinality notation:
-- A          = exactly one
-- Maybe A    = zero or one
-- [A]        = zero or many
-- NonEmpty A = one or many
--
-- =============================================================
-- 3. Corpora, Root, Groups
-- =============================================================

-- Corpora has three top-level responsibilities:
-- Root      = organizational hierarchy of Sapis
-- Interface = interaction surface
-- Computer  = shared execution environment / computer-use surface
data Corpora = MkCorpora
  { root      :: Root
  , interface :: Interface
  , computer  :: Computer
  }


-- Root is NOT a Group.
-- Root is the authoritative organizational tree.
--
-- Root explicitly contains:
--   exactly one Chief
--   zero or more direct Members
--   zero or more Groups
data Root = MkRoot
  { chief   :: Sapi
  , members :: [Sapi]
  , groups  :: [Group]
  }


-- A functional team of Sapis.
--
-- Every Group explicitly contains:
--   exactly one direct Leader
--   at least one direct Member besides the Leader
--   no subgroups
data Group = MkGroup
  { groupId  :: GroupId
  , purpose  :: GroupPurpose
  , leader   :: Sapi
  , members  :: NonEmpty Sapi
  }


-- Derived organizational position of a Sapi.
-- Root and Group membership above are authoritative.
data SapiPosition
  = Chief
  | RootMember
  | GroupLeader GroupId
  | GroupMember GroupId


-- Invariants:
--
-- Chief is a Sapi.
-- Leader is a Sapi.
-- Member is a Sapi.
-- Member may belong to Root or to one Group.
-- A Member may belong directly to Root or to one Group.
--
-- Chief cannot be a Group Leader.
-- Root may contain zero or more direct Members.
-- Root may contain zero or more Groups.
-- Chief must not also appear in Root.members.
-- Every Group has exactly one Leader.
-- Every Group has one or more Members besides its Leader.
-- Therefore every Group contains at least two Sapis total.
-- Leader must not also appear in Group.members.
-- Every Group belongs directly to Root; Groups cannot contain subgroups.
-- Root is not a Group.




-- Organizational invariants:
--
-- Root / Group hierarchy is the authoritative source of all Sapis.
-- There is no separate Corpora-level Sapi registry.
--
-- Every Sapi appears exactly once in the Root / Group tree:
--   Chief
--   RootMember
--   GroupLeader GroupId
--   GroupMember GroupId
--
-- Direct memberships of distinct Groups are disjoint.
-- A Sapi cannot directly belong to more than one Group.
--
-- Every Group has exactly one Leader
-- and at least one Member besides that Leader.
--
-- Organization is flat: Root has a single level of Groups.
-- A Root containing only Chief is valid.
-- Root membership and Group membership are disjoint.


-- =============================================================
-- 4. Sapi
-- =============================================================

-- Persistent autonomous agent inside Sapiens.
--
-- SapiHarness executions are transient; AgencyRun records may persist.
-- The Sapi persists across executions.
data Sapi = MkSapi
  { sapiId   :: SapiId
  , profile  :: Profile
  , memo     :: Memo
  , kit      :: Kit
  , agencies :: [AgencySetting]
  }


-- Persistent identity and human-defined description of a Sapi.
data Profile = MkProfile
  { identity         :: Identity
  , manifest         :: Manifest
  , organization     :: OrgPosition
  , responsibilities :: [Responsibility]
  , settings         :: Settings
  }


-- =============================================================
-- 5. Memo
-- =============================================================

-- Complete persistent memory of a Sapi.
--
-- Human-readable and internally hyperlinked; Memo replaces Wiki terminology.
newtype Memo =
  MkMemo [MemoNode]


-- One addressable unit inside Memo.
data MemoNode = MkMemoNode
  { nodeId  :: MemoNodeId
  , content :: Content
  , links   :: [MemoNodeId]
  }


-- Selected part of Memo supplied to one AgencyRun.
--
-- A SubMemo is a derived view of Memo.
-- It is not an independent memory store.
newtype SubMemo =
  MkSubMemo [MemoNodeId]


-- Memory invariant:
--
-- One canonical Memo per Sapi.
-- Zero or many SubMemos may be derived from it.


-- =============================================================
-- 6. Agency, SapiHarness, and AgencyRun
-- =============================================================

-- The purpose of a harnessed LLM definition.
data AgencyKind
  = Chat       -- conversation with humans or other Sapis
  | Memo       -- maintains canonical Memo; formerly Wiki
  | Jobs       -- creates, inspects, or repairs deterministic Jobs
  | Tasks      -- performs reasoning-driven Tasks
  | Healer     -- diagnoses failure and reasons about recovery
  | Claw       -- computer-use reasoning and interaction
  | Skills     -- creates and maintains reusable Skills


-- Agency is the harnessed LLM definition/constructor, not just its kind.
-- HarnessedLLM describes its model and harness configuration; details remain
-- abstract. Context and output Contract are supplied separately in SapiHarness.
data Agency = MkAgency
  { kind    :: AgencyKind
  , harness :: HarnessedLLM
  }


-- The Memo constructor above names an AgencyKind.
-- The Memo type in section 5 names persistent memory, built with MkMemo.
-- Jobs Agency may author a script; executing that script is a JobRun,
-- which must not invoke an LLM, even indirectly.
data AgencyState
  = Activated
  | Deactivated


data AgencySetting = MkAgencySetting
  { agency      :: Agency
  , agencyState :: AgencyState
  }


-- Structural composition in the ontology:
-- Agency   = harnessed LLM definition/constructor
-- Context  = what goes in
-- Contract = what valid output must satisfy
data SapiHarness a = MkSapiHarness
  { agency   :: Agency
  , context  :: Context
  , contract :: Contract a
  }


-- The execution record produced by running a SapiHarness once.
-- Retains the exact input structure and either its result or failure.
-- actor must be a Sapi or System; Admin does not execute an LLM directly.
data AgencyRun a = MkAgencyRun
  { agencyRunId  :: AgencyRunId
  , actor        :: Actor
  , sapiHarness :: SapiHarness a
  , result       :: AgencyResult a
  }


type AgencyResult a = Either AgencyError a


-- Many SapiHarness executions may run concurrently for one Sapi.
-- Each produces its own AgencyRun; the shared Computer still has one owner.
runSapiHarnesses
  :: Actor
  -> [SapiHarness a]
  -> IO [AgencyRun a]
runSapiHarnesses = undefined


-- =============================================================
-- 7. Context
-- =============================================================

-- Context assembled as input to a SapiHarness execution.
data Context = MkContext
  { promptTemplate :: PromptTemplate
  , subMemo        :: Maybe SubMemo
  , call           :: Maybe Call
  , logs           :: [Log]
  , state          :: Maybe ContextState
  }


-- Generalized prompt with injectable / replaceable parts.
newtype PromptTemplate =
  MkPromptTemplate Template


-- Maybe means legitimate absence.
--
-- subMemo :: Maybe SubMemo
--   The AgencyRun may not need Memo context.
--
-- call :: Maybe Call
--   Some AgencyRuns are not caused directly by a Call.
--
-- state :: Maybe ContextState
--   Some AgencyRuns may not require additional runtime state.
--
-- logs :: [Log]
--   Zero logs is represented by [] rather than Maybe [Log].


-- =============================================================
-- 8. Contract
-- =============================================================

-- Formal requirements for a valid AgencyRun result.
data Contract a = MkContract
  { objective   :: Objective
  , constraints :: [Constraint]
  , output      :: OutputSchema a
  }


runSapiHarness
  :: Actor
  -> SapiHarness a
  -> IO (AgencyRun a)
runSapiHarness = undefined


validate
  :: Contract a
  -> RawAgencyOutput
  -> Either ContractError a
validate = undefined


-- Core distinction:
--
-- Context  = what goes in.
-- Contract = what must come out.


-- =============================================================
-- 9. Call + Triage
-- =============================================================

-- Invocation addressed to a Sapi.
--
-- Origin can be Admin, another Sapi, or System.
data Call = MkCall
  { origin      :: Actor
  , target      :: SapiId
  , intent      :: Intent
  , callContext :: Maybe CallContext
  }


-- Assessment of an incoming Call.
triage
  :: Sapi
  -> Call
  -> TriageDecision
triage = undefined


data TriageDecision
  = Repl
  | Execute
  | Delegate SapiId
  | Escalate
  | Clarify


-- Conceptual flow:
--
-- Call -> Triage -> Execution


-- =============================================================
-- 10. Kit
-- =============================================================

-- Operational automation owned and evolved by a Sapi.
data Kit = MkKit
  { skills  :: [Skill]
  , scripts :: [Script]
  , tools   :: [Tool]
  , jobs    :: [Job]
  , dispos  :: [Dispo]
  }


-- Reusable know-how describing how to perform a capability.
data Skill = MkSkill
  { instructions :: Instructions
  , uses         :: [ToolId]
  }


-- Deterministic executable program.
--
-- Typically Python in the current architecture.
data Script = MkScript
  { scriptId :: ScriptId
  , code     :: ScriptCode
  , version  :: Version
  }


-- Reusable executable operation.
data Tool = MkTool
  { toolId         :: ToolId
  , implementation :: ScriptId
  , inputSchema    :: Schema
  , outputSchema   :: Schema
  }


-- Temporary disposable automation created for a specific need.
data Dispo = MkDispo
  { dispoScript :: Script
  , expires     :: Maybe Time
  }


-- =============================================================
-- 11. Task and TaskRun
-- =============================================================

-- Work definition assigned to an Actor.
-- A TaskRun performs this work using Agency; a JobRun executes a script.
-- Human-owned work can be described by Task, but human execution is not a
-- TaskRun: this notation models TaskRun as LLM-assisted execution.
-- assignee, startAt, and dueAt are mandatory.
data Task = MkTask
  { taskId   :: TaskId
  , assignee :: Actor
  , startAt  :: Time
  , dueAt    :: Time
  , spec     :: TaskSpec
  }


-- One execution attempt of a Task. Retry creates a new TaskRunId.
-- AgencyRun references preserve provenance without copying LLM results.
data TaskRun = MkTaskRun
  { taskRunId :: TaskRunId
  , task      :: Task
  , status    :: TaskStatus
  , agencies  :: [AgencyRunId]
  }


data TaskStatus
  = TaskPending
  | TaskRunning
  | TaskWaiting WaitReason
  | TaskCompleted Outcome
  | TaskFailed TaskError
  | TaskCancelled


-- Task invariants:
-- assignee, startAt, and dueAt always exist; startAt <= dueAt.
-- A TaskRun's assignee is Sapi or System.
-- A completed TaskRun must reference at least one AgencyRun.
-- Pending/cancelled attempts may have none; attempts retain produced AgencyRuns.
-- Each referenced AgencyRun belongs to this task's assignee.
-- Task definition and execution status are separate; prior attempts are retained.


-- =============================================================
-- 12. Job and JobRun
-- =============================================================

-- Deterministic automation definition, normally owned in a Sapi's Kit.
-- A JobRun must execute without Agency or any other LLM invocation.
data Job = MkJob
  { jobId          :: JobId
  , assignee       :: Actor
  , implementation :: ScriptId
  , spec           :: JobSpec
  }


data JobRun = MkJobRun
  { jobRunId      :: JobRunId
  , job           :: Job
  , scriptVersion :: Version
  , status        :: JobStatus
  }


data JobStatus
  = JobPending
  | JobRunning
  | JobRetrying Int
  | JobCompleted JobOutcome
  | JobFailed JobError
  | JobOutcomeUnknown
  | JobCancelled


-- OutcomeUnknown is distinct from Failed: an external side effect may have
-- happened before a crash. Do not blindly retry it and duplicate that effect.
-- A new execution attempt gets a new JobRunId and records its script version.
-- Jobs/Healer Agency may diagnose or change the script outside the JobRun.
-- Such reasoning is a separate AgencyRun, never hidden inside a JobRun.


-- =============================================================
-- 13. Scheduled and conditional work
-- =============================================================

-- A Routine is a Task definition activated by Scheduler.
data Routine = MkRoutine
  { routineSchedule :: Schedule
  , routineAssignee :: Actor
  , routineTask     :: TaskSpec
  }


-- A Cron is a Job definition activated by Scheduler.
data Cron = MkCron
  { cronSchedule :: Schedule
  , cronAssignee :: Actor
  , cronJob      :: JobSpec
  }


-- A Trigger creates a Task when its Condition is met.
data Trigger = MkTrigger
  { triggerCondition :: Condition
  , triggerAssignee  :: Actor
  , triggerTask      :: TaskSpec
  }


-- A Cue creates a Job when its Condition is met.
data Cue = MkCue
  { cueCondition :: Condition
  , cueAssignee  :: Actor
  , cueJob       :: JobSpec
  }


-- Semantics:
--
-- Scheduler -> Routine -> Task
-- Scheduler -> Cron    -> Job
--
-- Condition -> Trigger -> Task
-- Condition -> Cue     -> Job
--
-- TaskRun = execution with Agency.
-- JobRun  = script execution without Agency.


-- =============================================================
-- 14. WorkGraph, WorkFlow, and their runs
-- =============================================================

-- Both graph kinds mix Task and Job definitions.
-- StepId addresses either kind, so dependencies can cross Task/Job boundaries.
data WorkStep = MkWorkStep
  { stepId :: StepId
  , work   :: WorkUnit
  }


data WorkUnit
  = TaskStep Task
  | JobStep Job


data Dependency = MkDependency
  { upstream   :: StepId
  , downstream :: StepId
  , condition  :: Condition
  }


-- A mixed graph scoped to exactly one Sapi.
-- Every Task and Job in it is assigned to that Sapi.
data WorkGraph = MkWorkGraph
  { graphId      :: GraphId
  , revision     :: Revision
  , sapi         :: SapiId
  , contract     :: Contract Outcome
  , steps        :: [WorkStep]
  , dependencies :: [Dependency]
  }


-- A crystallized collaborative graph scoped to one Group.
-- Every step has one accountable Sapi assignee from that Group.
-- Leader coordinates; members can perform, verify, and heal each other's work.
-- Participants are the Group Leader and its direct Members.
-- There are no subgroups or inherited memberships.
data WorkFlow = MkWorkFlow
  { workFlowId   :: WorkFlowId
  , revision     :: Revision
  , group        :: GroupId
  , contract     :: Contract Outcome
  , recovery     :: RecoveryPolicy
  , steps        :: [WorkStep]
  , dependencies :: [Dependency]
  }


-- References to concrete attempts; repeated attempts retain the same StepId.
data StepRun = MkStepRun
  { stepId  :: StepId
  , attempt :: StepAttempt
  }


data StepAttempt
  = TaskAttempt TaskRunId
  | JobAttempt JobRunId


data WorkGraphRun = MkWorkGraphRun
  { workGraphRunId :: WorkGraphRunId
  , definition     :: WorkGraph
  , agencies       :: [AgencyRunId]
  , attempts       :: [StepRun]
  , status         :: WorkRunStatus
  }


data WorkFlowRun = MkWorkFlowRun
  { workFlowRunId :: WorkFlowRunId
  , definition    :: WorkFlow
  , agencies      :: [AgencyRunId]
  , attempts      :: [StepRun]
  , status        :: WorkRunStatus
  }


data WorkRunStatus
  = WorkPending
  | WorkRunning
  | WorkVerifying
  | WorkHealing
  | WorkWaiting WaitReason
  | WorkCompleted Outcome
  | WorkFailed WorkError
  | WorkCancelled


-- Execution matrix:
-- JobRun       : script only; no LLM/Agency.
-- TaskRun      : Agency-assisted work.
-- WorkGraphRun : Agency-assisted mix of TaskRuns/JobRuns for ONE Sapi.
-- WorkFlowRun  : Agency-assisted mix of TaskRuns/JobRuns for ONE Group.
--
-- Run invariants:
-- Definitions/revisions and individual execution attempts are distinct.
-- Run IDs and AgencyRun IDs are unique; references resolve to recorded runs.
-- A StepAttempt must match its WorkUnit kind and the assigned Task/Job.
-- WorkGraphRun AgencyRuns belong to its single Sapi.
-- WorkFlowRun AgencyRuns belong to its assigned Group's participating Sapis.
-- agencies records coordination/verification/healing; TaskRun records its own
-- AgencyRuns. A run's total Agency includes both, without duplicate execution.
-- A completed graph/flow run has at least one AgencyRun across those records.
-- Its JobRuns remain script-only even when Agency chooses or verifies them.
--
-- Graph invariants:
-- StepIds are unique within a definition; dependency endpoints must exist.
-- Dependencies are acyclic within a revision. Recovery creates new attempts
-- or an explicit new revision; it does not turn the dependency graph cyclic.
-- A step may start only when its dependency conditions are satisfied.
-- Trigger creates a Task; satisfying a dependency activates an existing step.
--
-- Collaborative verification and healing:
-- Verification is represented by Tasks/Jobs with explicit acceptance criteria.
-- Peer verification assigns a different Sapi from the producer where required.
-- Healing diagnoses failure and records repair/retry attempts under recovery.
-- RecoveryPolicy defines retry bounds, permitted repairs, and escalation.
-- Uncertain effects require reconciliation before another external action.
-- WorkCompleted requires evidence satisfying the overall Contract, not just
-- stopped steps. Repairing a run does not silently rewrite its definition.


-- =============================================================
-- 15. System
-- =============================================================

-- System is the singleton Sapiens platform Actor.
--
-- System may perform deterministic work or use LLM Agency.
data SystemScope
  = CorporaMaintenance
  | AppMaintenance
  | Platform PlatformScope


data PlatformScope
  = Updates
  | Offline


-- System may use an LLM without becoming a Sapi.
-- The AgencyRun must record actor = System, with its own AgencyRunId.
systemAgency
  :: SystemScope
  -> SapiHarness a
  -> IO (AgencyRun a)
systemAgency = undefined


-- =============================================================
-- 16. High-level ontology
-- =============================================================
--
-- Sapiens
-- |
-- +-- Corpora
-- |   +-- Root
-- |   +-- Interface
-- |   \-- Computer
-- |
-- +-- Actor
-- |   +-- Admin
-- |   +-- Sapi SapiId
-- |   \-- System
-- |
-- +-- Organization
-- |   \-- Root
-- |       +-- Chief [exactly 1]
-- |       +-- Members [0..*]
-- |       \-- Groups [0..*]
-- |           \-- Group
-- |               +-- Leader [exactly 1]
-- |               \-- Members [1..*]
-- |
-- +-- SapiHarness
-- |   +-- Agency
-- |   +-- Context
-- |   \-- Contract
-- |
-- \-- Work
--     +-- Task -> TaskRun (with Agency)
--     |   +-- Routine  -> Task by Scheduler
--     |   \-- Trigger  -> Task by Condition
--     |
--     +-- Job -> JobRun (script only)
--     |   +-- Cron     -> Job by Scheduler
--     |   \-- Cue      -> Job by Condition
--     +-- WorkGraph -> WorkGraphRun (mixed; one Sapi)
--     \-- WorkFlow  -> WorkFlowRun  (mixed; one Group)


-- =============================================================
-- 17. Core terminology
-- =============================================================
--
-- Sapiens
--   Project / system.
--
-- Actor
--   Admin | Sapi SapiId | System.
--
-- Admin
--   Singleton human actor.
--
-- Sapi
--   Persistent autonomous agent; Sapi and agent are synonyms.
--
-- System
--   Singleton Sapiens platform actor.
--
-- Corpora
--   Root + Interface + Computer.
--
-- Root
--   Authoritative organizational tree of all Sapis.
--   Chief acts as its lead. May contain direct Members and Groups.
--   Root is not a Group.
--
-- Chief
--   Sapi that leads Root.
--
-- RootMember
--   Sapi directly belonging to Root.
--
-- Group
--   Functional team with exactly one Leader,
--   one or more direct Members, and no subgroups.
--
-- SapiPosition
--   Derived view of where a Sapi belongs:
--   Chief | RootMember | GroupLeader GroupId | GroupMember GroupId.
--
-- Leader
--   Sapi directly leading one Group.
--
-- Member
--   Sapi directly belonging to Root or one Group.
--
-- Agency
--   Harnessed LLM definition/constructor.
--
-- AgencyKind
--   Chat, Memo, Jobs, Tasks, Healer, Claw, Skills.
--
-- SapiHarness
--   Agency + Context + Contract; the structure supplied for execution.
--
-- AgencyRun
--   Execution record/result produced by running a SapiHarness once.
--
-- Memo
--   Complete persistent Sapi memory.
--
-- SubMemo
--   Selected part of Memo.
--
-- PromptTemplate
--   Generalized prompt structure.
--
-- Context
--   Input supplied through SapiHarness.
--
-- Contract
--   Formal requirements for a valid AgencyRun result.
--
-- Call
--   Invocation addressed to a Sapi.
--
-- Triage
--   Decision about how a Sapi handles a Call.
--
-- Task
--   Actor-assigned work definition; TaskRun executes with Agency.
--   assignee, startAt, and dueAt are mandatory.
--
-- Job
--   Script automation definition; JobRun executes without Agency.
--
-- WorkGraph / WorkGraphRun
--   Mixed Task/Job graph / its Agency-assisted execution for one Sapi.
--
-- WorkFlow / WorkFlowRun
--   Collaborative mixed graph / its Agency-assisted execution for one Group.
--
-- Routine
--   Task created by Scheduler.
--
-- Cron
--   Job created by Scheduler.
--
-- Trigger
--   Task created when a Condition is met.
--
-- Cue
--   Job created when a Condition is met.
--
-- Script
--   Deterministic executable code.
--
-- Skill
--   Reusable know-how.
--
-- Tool
--   Reusable executable operation.
--
-- Dispo
--   Temporary disposable automation.
--
-- Kit
--   Operational automation owned by a Sapi.


-- =============================================================
-- 18. Current invariants
-- =============================================================
--
-- Admin and System are singletons.
-- Sapi is identified by SapiId.
--
-- Corpora has exactly one Root, one Interface, and one Computer.
--
-- Root is not a Group.
-- Root is the authoritative owner of all Sapis in the organization.
-- Root explicitly stores one Chief, zero or more direct Members,
-- and zero or more Groups.
-- Chief cannot lead a Group.
--
-- Every Sapi has exactly one direct organizational position.
-- Sapi group membership is a strict non-overlapping partition.
-- Direct Group memberships never overlap.
--
-- Every Group explicitly stores exactly one direct Leader
-- and at least one direct Member besides its Leader.
-- Every Group belongs directly to Root; no subgroup nesting is allowed.
--
-- Sapi persists.
-- Execution is transient; its AgencyRun record may persist.
--
-- One Sapi may execute multiple specialized SapiHarnesses concurrently.
--
-- Memo is canonical persistent memory.
-- SubMemo is a selected view of Memo.
--
-- SapiHarness combines Agency, Context, and Contract.
-- Executing SapiHarness produces AgencyRun.
-- Contract defines valid output; AgencyRun records the result or failure.
--
-- Every Task has an assignee.
-- Every Task has startAt.
-- Every Task has dueAt.
--
-- TaskRun and JobRun are different:
-- TaskRun = execution with Agency.
-- JobRun  = script execution without Agency.
--
-- Routine and Trigger create Tasks.
-- Cron and Cue create Jobs.
-- WorkGraphRun belongs to one Sapi; WorkFlowRun belongs to one Group.
-- Both mix TaskRuns and JobRuns, with Agency for execution/coordination.
-- JobRun never includes Agency, including when embedded in either graph.
--
-- rTernarity applies to meaningful architectural decomposition,
-- not arbitrary domain cardinality.


-- =============================================================
-- 19. Placeholder domain types
-- =============================================================

data SapiId

data Interface
data Computer
data GroupId
data GroupPurpose

data Identity
data Manifest
data OrgPosition
data Responsibility
data Settings

data MemoNodeId
data Content
data Template

data CallContext
data ContextState
data Log

data Objective
data Constraint
data OutputSchema a
data AgencyError
data ContractError
data RawAgencyOutput

data Intent

data Instructions
data ToolId
data ScriptId
data ScriptCode
data Version
data Schema

data Time
data Schedule

data TaskId
data TaskSpec
data TaskError
data WaitReason
data Outcome

data JobId
data JobSpec
data JobError
data JobOutcome

data Condition

data GraphId
data Revision

-- Execution and mixed-graph identities.
data AgencyRunId
data TaskRunId
data JobRunId
data StepId
data WorkFlowId
data WorkGraphRunId
data WorkFlowRunId
data WorkError
data RecoveryPolicy

-- Harnessed LLM definition (model and harness configuration).
data HarnessedLLM

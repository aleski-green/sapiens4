# Sapi work execution: terminology and notation

Status: design specification. This document describes the intended work model;
it does not claim that task graphs, triggers, or delegation are implemented.
See the [runtime reference](../reference.md) for current behavior.

Haskell syntax is used only as a descriptive DSL in Markdown. The fragments are
readable specifications, not a compilable module. They are not compiled,
interpreted, executed, used as model prompts, or used for code generation.

## 1. Vocabulary and notation

Every activation of a Sapi begins with a **Call**. A task describes work; a call
activates a Sapi to handle it. One workload can require several calls and tasks.

| Term | Meaning |
| --- | --- |
| `Admin` | The human requesting work or providing direction. |
| `Sapi` | An agent with a role and specialization that receives calls. |
| `Chief` | A Sapi responsible for team triage, with broader context about specializations and current work. |
| `Workload` | The requested work and intended result, retaining its identity across calls, delegation, and graph revisions. |
| `Call` | An invocation addressed to a Sapi, carrying intent, context, and its origin. |
| `Triage` | Assessment of the request, suitability of the receiving Sapi, and the next course of action. |
| `Execution` | Work performed toward the requested result, potentially including tools, observations, and planning. |
| `Task` | A defined unit of work whose type and specification establish inputs, expected outputs, and completion criteria. |
| `Trigger` | An activation event that produces a call when the associated task is eligible. |
| `Dependency` | A directed prerequisite relationship between tasks, with a condition governing readiness. |
| `WorkGraph` | A directed acyclic graph of tasks, dependencies, and conditions. |
| `Outcome` | A result of work, including success, failure, or an explicit unresolved requirement. |
| `Reply` | Communication of an outcome to the caller; an outcome can include artifacts or other effects beyond its reply. |
| `Observation` | New information gathered or received while work is being handled. |
| `ExecutionState` | Recorded progress and effects: pending, running, completed, blocked, or otherwise resolved task attempts and their outcomes. |
| `WorkGraphMorphism` | A revision of a work graph in light of observations and execution so far. |

Actors, work states, and graph structure are distinct. For example, `Chief` is an
actor, `Running` describes execution state, and a dependency belongs to a graph.

```haskell
-- Notation only; operators describe relationships.
-- a --> b    : b follows a
-- a :& b     : both are produced; no ordering or concurrency implied
-- a :| b     : alternative results of this decision
-- ::         : conceptual type or relationship signature

data Mode = Repl | Exec | Delegation
```

Parentheses make grouping explicit. Capitalized flow labels name conceptual
stages or results. Lowercase names such as `graphN` and `task` are placeholders,
not prescribed task types. Type names such as `TaskSpec`, `Condition`, and
`Observation` remain abstract until their domain-specific meanings are defined.

## 2. Calls, modes, and delegation

```haskell
replMode =
  Call --> Triage --> (Outcome :& Reply)

execMode =
  Call --> Triage --> Execution --> (Outcome :| WorkGraph)

delegationMode =
  Call --> Triage --> Delegation --> execMode
```

**REPL is one-step delivery.** One call produces its outcome and reply. Reaching
that delivery may involve multiple model or tool steps; it is not restricted to
one model response. Persistent task graphs belong to the Exec path.

**Exec performs work or expands it into a graph.** Producing a `WorkGraph`
describes remaining work; it does not by itself establish that the original
workload is complete. Tasks and graph structure depend on the workload and task
types, rather than a fixed pipeline.

**Delegation hands execution to another Sapi.** The transition into `execMode`
creates a call addressed to that recipient. The recipient performs its own
triage, so assignment does not imply that suitability is already established.
A recipient that cannot handle the work can delegate again.

The supported routing relationships are:

```haskell
delegationRoutes =
  [ Admin --> Sapi
  , Admin --> Chief
  , Chief --> Sapi
  , Sapi  --> Chief
  ]

-- State, decision event, next state
delegationTransitions =
  [ (Assessing,   FitsSpecialization,    ReadyToWork)
  , (Assessing,   OutsideSpecialization, ChiefTriage)
  , (ChiefTriage, SpecialistSelected,    Assessing)
  , (ChiefTriage, NewSpecialistNeeded,   CreatingSapi)
  , (CreatingSapi, SpecialistCreated,   Assessing)
  , (ChiefTriage, RequestUnclear,        WaitingForAdmin)
  , (WaitingForAdmin, RequestClarified,  ChiefTriage)
  ]
```

The first receiving Sapi assesses the workload. A suitable Sapi prepares a task
or task sequence and works on it; one outside its specialization refers it to
Chief by default. Chief may select an existing Sapi, create a suitable Sapi, or
request clarification. Chief can also execute work within its own specialization.

On referral, Chief becomes responsible for triage. On assignment or creation,
the selected Sapi becomes responsible for assessing and executing the work.
Repeated rejection must surface an unresolved routing decision rather than
silently circulate the same workload forever.

Each call has its own identity. A delegated call preserves the workload identity,
original intent, relevant context, handoff reason, and the identity of the call
that caused it. Each task has one accountable owner; a graph can contain tasks
owned by different Sapis. A handoff records responsibility before the recipient
starts work, and the original requester remains identifiable for reporting.

### Task activation

```haskell
taskActivation =
  Task --> ReadinessSatisfied --> Trigger --> Call
```

This expands `Task --> Trigger --> Call`: dependencies and activation conditions
govern when a trigger may produce the call. Conditions may involve prior task
outcomes, newly observed data, an event, or time. A task without prerequisites can
be eligible immediately.

The task specification defines how prerequisites combine and which outcomes
satisfy them. Multiple predecessors do not imply a universal rule such as
"every predecessor must succeed"; a failure-handling task can depend on failure.
An unsatisfied condition does not authorize execution. A repeat activation is a
distinct recorded attempt, not an implicit duplicate of an existing call.

## 3. Work graphs and their evolution

The graph is generic. There is no fixed task taxonomy, sequence, or branch count.
Tasks can be independent, sequential, parallel, or conditionally activated.

```haskell
data Task = Task
  { taskId        :: TaskId
  , taskType      :: TaskType
  , specification :: TaskSpec
  }

data Dependency = Dependency
  { upstream   :: TaskId
  , downstream :: TaskId
  , condition  :: Condition
  }

data WorkGraph = WorkGraph
  { graphId      :: GraphId
  , revision     :: Revision
  , tasks        :: [Task]
  , dependencies :: [Dependency]
  }
```

Task IDs are unique within a graph, dependency endpoints refer to tasks in that
revision, and dependencies remain acyclic. `TaskType` and `TaskSpec` define the
work's meaning, accepted inputs, outputs, activation rules, and completion criteria.
Execution state is tracked separately from the plan's structure.

A graph can produce further calls without introducing a dependency cycle:

```haskell
workExpansion =
  Call --> Triage --> Execution --> WorkGraph
       --> Task --> Trigger --> Call
```

This is a repeating control flow across invocations. A task in any graph revision
must still never depend on itself through a chain of dependencies.

### WorkGraphMorphism

An observation may reveal that the current tasks, dependencies, or conditions
need to change. `WorkGraphMorphism` names that change to the plan during execution.

```haskell
-- Describes the inputs and result of a valid revision; not executable code.
type WorkGraphMorphism =
  (WorkGraph, ExecutionState, Observation) -> WorkGraph

graphProgress =
  (graphN, stateBefore) --> TaskOutcome --> (graphN, stateAfter)

graphRevision =
  (graphN, stateNow) --> Observation --> WorkGraphMorphism
                    --> (graphNext, reconciledState)
```

Ordinary progress updates execution state within the same graph revision.
New data that satisfies an existing condition is ordinary progress. A morphism
changes the plan and produces a new revision of the same graph and workload.
Reconciliation determines how existing task attempts relate to that new plan.

A morphism may add, remove, split, combine, or revise tasks, dependencies, and
conditions. Unchanged tasks retain their identities. Replacement, split, or
combined tasks retain lineage to the tasks they supersede. The prior revision,
causing observation, and relationship between revisions remain recorded.

Graph revision happens while a Sapi is handling a call. The observation is either
input to the current call or grounds for a trigger producing a subsequent call.
`WorkGraphMorphism` is an operation within work execution, not a fourth mode.

Three requirements govern a valid revision:

1. **Preserve history.** Completed actions and outcomes remain recorded. New
   evidence can make their results obsolete or require new work; it cannot undo
   past effects or rewrite what actually occurred.
2. **Reconcile active work.** Each affected running task explicitly continues,
   is cancelled where possible, or finishes with its result marked obsolete.
   Unaffected tasks can continue. Results retain their originating task attempt
   and revision; obsolete results cannot silently satisfy new dependencies.
3. **Preserve graph validity.** The next revision remains a DAG with valid
   endpoints and task-type-compatible inputs, outputs, and conditions. Changing
   prerequisites of running or completed work requires explicit reconciliation,
   not a retroactive claim that the new prerequisites were satisfied.

The name is domain-specific. A mathematical graph morphism preserves graph
structure; arbitrary additions, removals, and dependency changes are generally
described as graph transformation or rewriting. This specification uses
`WorkGraphMorphism` for a revision preserving execution history and the invariants
above, without claiming a formal category-theoretic construction. See
[A Tutorial on Graph Transformation, definitions 2 and 5](https://ris.utwente.nl/ws/portalfiles/portal/247999750/K_nig2018tutorial.pdf).

### Decisions still open

- **Mode selection:** whether the caller supplies a mode, triage selects it, or
  both participate; precedence is not defined here.
- **Graph completion and reporting:** who owns the graph-level result, how
  conditional or unresolved tasks affect completion, and whether the original
  call waits, returns the plan, or receives a later reply.
- **Revision authority and coordination:** who may propose or accept a morphism,
  how concurrent proposals are reconciled against the current revision, and how
  task activation is coordinated with replacing that revision.

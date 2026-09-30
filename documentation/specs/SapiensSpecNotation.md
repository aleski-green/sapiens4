# Sapiens architecture notation: Agency and execution runs

The [Haskell notation](SapiensSpecNotation.hs) is a working architecture
specification. **Agency** is a harnessed LLM definition/constructor.
**SapiHarness** combines Agency, Context, and Contract; executing it produces
an **AgencyRun**, the execution record with its result or failure. Sapi and agent are synonyms. **Memo** replaces
Wiki as the name of persistent Sapi memory and also names the Agency that
maintains it.

The file originated from the workspace artifact
`.sapiens4/workspaces/sapi_26220193ca50/artifacts/SapiensSpecNotation.hs`, imported
on 2026-09-30. It was subsequently revised at the user's request to introduce
Agency, Memo, and the four execution scopes below. On 2026-10-01 the organization
was restricted to a single level of Groups, and SapiHarness was introduced to
distinguish the input structure from its resulting AgencyRun. The workspace original remains
unchanged; the documentation copy is no longer byte-identical to it. The original
SHA-256 was `9f9006f2c884406730d52cb12696ad12875432d33841106a47cb432b443bc6cb`.

These are design changes, not enabled runtime features. The implementation
comparison below refers to revision `a32c2e7` and [delegation v1](../delegation.md).

## Flat organization

Root contains exactly one required Chief, zero or more direct Sapis, and zero or
more Groups. A Root containing only Chief is valid. Each Group contains exactly
one Leader and at least one other Sapi; Groups cannot contain subgroups.

Every Sapi has exactly one position: Chief, Root member, Group Leader, or Group
member. Chief cannot also lead a Group or appear in Root's member list. A Group's
Leader is separate from its member list, and memberships do not overlap.

## Agency and Memo

Agency contains its `AgencyKind` (`Chat`, `Memo`, `Jobs`, `Tasks`, `Healer`,
`Claw`, or `Skills`) and a harnessed LLM definition. It is more than a purpose
label. A Sapi enables or disables its Agencies through `AgencySetting`.

The structural composition is `SapiHarness = Agency + Context + Contract`.
`runSapiHarness` executes this structure for an actor and returns an AgencyRun,
which records its identity, actor, exact SapiHarness, and result or failure.
AgencyRun is the product of execution, not the name of the three-part structure.
Multiple AgencyRuns can belong to one TaskRun.

`Jobs` Agency can write or repair a script. Executing that script is a JobRun and
must not invoke an LLM. If execution requires reasoning, that reasoning belongs
to a separate AgencyRun, usually within a TaskRun or graph/flow coordination.
A script that calls an LLM does not qualify as a script-only JobRun.

The `Memo` type stores canonical persistent memory; `MemoNode` identifies its
addressable units and `SubMemo` selects them. The `Memo` constructor of `AgencyKind`
names memory work, while `MkMemo` constructs the memory value. These meanings
are explicit in the notation. Runtime `Notes.html` is not renamed by this change.

## Four execution scopes

| Definition / execution | Behavior | Scope |
| --- | --- | --- |
| Job / JobRun | Executes a versioned script without Agency | Assigned actor; normally a Sapi's Kit |
| Task / TaskRun | Performs work with Agency | Assigned Sapi or System |
| WorkGraph / WorkGraphRun | Mixes TaskRuns and JobRuns with Agency | Exactly one Sapi |
| WorkFlow / WorkFlowRun | Mixes TaskRuns and JobRuns with Agency, peer verification, and healing | One Group of Sapis |

Definitions and execution attempts are separate. Status belongs to the run;
retrying creates another run identity. A graph/flow run retains its definition
revision and step-attempt references. TaskRun records its AgencyRun references;
graph/flow runs additionally record coordination, verification, or healing runs.
Referenced results are not copied or implicitly executed again.

Pending and cancelled runs can have no AgencyRuns. Successful TaskRuns and
successful graph/flow runs must have Agency evidence in their own or nested run
records. JobRuns never contain Agency, even when embedded in a larger process.
Human work may still be described by Task, but a human-only execution is outside
the newly defined Agency-assisted TaskRun model.

## Collaboration, verification, and healing

A WorkFlow is a crystallized collaborative graph owned by one Group. Every step
has one accountable Sapi. The Leader coordinates the shared outcome; participating
Sapis can execute, verify, and repair work. Participants are the Group's Leader
and direct members; every step's assignment is explicit. There are no subgroups
or inherited memberships.

Both WorkGraph and WorkFlow use WorkSteps containing either a Task or a Job.
Dependencies refer to StepIds so they can connect either kind. A definition
revision remains acyclic. Recovery adds attempts or explicitly revises the plan;
it does not insert an unbounded cycle into the dependency graph.

Verification is work with acceptance criteria. It can be a reasoning Task or a
deterministic Job. Where peer review is required, the verifier differs from the
producer. Healing uses recorded diagnosis and repair attempts; RecoveryPolicy
must define limits and escalation. An uncertain external effect must be
reconciled before retrying. Completion requires evidence satisfying the overall
Contract, not merely that every step has stopped.

## Relation to the earlier design and current implementation

| Area | Revised notation | Current behavior / remaining difference |
| --- | --- | --- |
| Organization | Root owns Chief, optional direct Sapis, and one level of Groups | [Registry](../../sapiens/corpora/sapis/registry.py) stores parent relationships; SQLite also stores agents. Groups are inactive. |
| Agency / SapiHarness | Harnessed LLM definitions, combined with Context and Contract for execution | [Delegation](../../sapiens/corpora/host/delegation.py) has decision-node prompts and recorded responses. These nodes are not the Agency taxonomy. |
| Concurrency | Multiple SapiHarness executions can produce AgencyRuns for one Sapi | [Service](../../sapiens/corpora/host/service.py) serializes work within a Sapi and runs different Sapis in parallel. Shared computer access has one owner. |
| Memo | Canonical linked memory with typed node selections | [Notes](../../sapiens/corpora/sapis/notes.py) uses Notes.html and about/map context. There is no typed SubMemo resolver. |
| WorkGraph | Mixed Task/Job graph for one Sapi | The [earlier WorkGraph specification](WorkGraph.md) describes task-only graphs with potentially different Sapi owners; its graph interpreter is not implemented. |
| WorkFlow | Mixed graph for a Group, with verification and recovery | New design entity; not implemented. |
| Tasks and Jobs | Explicit definition/run distinction and Agency boundary | Delegation has task specifications, call attempts, and recovery records. Separate TaskRun/JobRun domain types and Job execution are not implemented. |
| Logs | Context can contain recorded evidence | Decision archives and transcripts remain; this does not restore the removed Log tab or activity feed. |

The revised notation establishes the intended distinction between WorkGraph and
WorkFlow. The earlier design remains useful for delegation, graph revision,
lineage, and recovery, but its ownership assumptions need translation before use
with the revised model.

## Decisions still needed before implementation

1. **Activation terminology:** the revised notation retains Trigger as a
   conditional Task factory. The earlier specification uses Trigger to activate
   a Call for an existing Task. Name that second operation TaskActivation and
   define occurrence deduplication; it must not accidentally create duplicate Tasks.
2. **Organizational authority:** reconcile derived SapiPosition with the still
   abstract `Profile.organization :: OrgPosition`. Specify group changes,
   retirement, and Chief-only Sapi creation authority explicitly.
3. **Dates and retries:** define startAt versus actual start, unscheduled work,
   overdue work, and how Routine/Trigger supply mandatory dates. Preserve
   interrupted and unresolved outcomes, attempt lineage, and uncertain effects
   for Tasks as well as Jobs.
4. **Concurrent Agency:** define admission, cancellation, Memo write conflicts,
   scope deactivation, and step transition ownership before removing per-Sapi
   serialization. Preserve the shared computer lease.
5. **Contracts and recovery:** define executable checks, evidence requirements,
   retry bounds, and who may revise a graph or escalate to Admin. The generic
   OutputSchema and RecoveryPolicy types remain placeholders.
6. **Reusable definitions:** define input binding and how task dates are
   instantiated for a new graph/flow run. Run status is separated, but definition
   parameters and immutable Task/Job revisions still need concrete representations.

No runtime rewrite is implied. First settle these contracts, then map existing
calls and decision records onto AgencyRun/TaskRun while retaining recovery
behavior. Groups, graph execution, scheduling, and concurrent Agency remain
separate implementation changes.

## Verification and limits

This file is documentation, not executable runtime code or a model prompt. Five
operation bodies remain `undefined`; domain leaf types and RecoveryPolicy are
abstract. IDs, ownership, Agency participation, and DAG invariants are specified
in comments and require validation in a future implementation.

GHC was unavailable during this revision, so compilation was not verified.
Documentation links, naming consistency, and preservation of the original
workspace artifact were checked. A type check alone would not prove behavioral
invariants.

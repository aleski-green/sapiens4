# Sapiens: navigation and workload

**2026-10-08 update:** [SystemPulsation.hs](SystemPulsation.hs) specifies the
implemented global Pulse clock and chat Agency batching. Its clock, slot,
context, and dispatch semantics supersede this document's earlier classifier-only
Pulse proposal. The remaining workload/automation design below is still a proposal.

The [Haskell notation](SapiensSpecNotation.hs) replaces the previous ontology
with the slide and Admin's clarifications of 2026-10-03. It describes the target
UI and workload behavior; it does not change the running application.

## Navigation

```text
Chat
Work
  Profile: Memo / Kit / Workspace
  Tasks: Adhoc / Workflow / Agile
  Automation
    Scheduler: Routine / Cron / Pulse
    Callback: Hook / Condition / Reaction
      Reaction: Trigger / Adhoc / Retry
    Workflow: Pipeline / Gantt / WBS
Updates: Runtime / Events / Archived
```

These are navigation branches. Profile is the work-related profile menu, not a
new identity ontology. Workflow work under Tasks and definitions under Automation
are proposed linked views of the same work rather than independent copies.

rTernarity applies recursively to meaningful responsibilities. Three parts,
three alternatives and three views are different relationships. Domain leaves
and cardinalities stay honest: two workflow initiators and two Pulse states do
not acquire artificial third siblings.

## Tasks and scheduling

- **Adhoc:** Issue, Mention, Inquiry. Must receive attention at the next Pulse;
  execute, requalify into other work, or dismiss. This does not guarantee that a
  long task finishes within one heartbeat.
- **Workflow:** multistep work, in the sense of n8n.
- **Agile:** planned, nonurgent work tracked through backlog, in progress, etc.
  The full board and any distinct Scrum semantics are still open.

**Routine** injects a prompt-template message into chat to call the target
Sapi's Agency. It keeps its automated provenance.

**Cron** starts a workflow by time. Its reaction policy also supports creating
Adhoc work, bounded retries, and dismissal. The precise conditions for these
alternatives still need agreement.

**Pulse** periodically runs a deterministic workload classifier, for example
every 3 or 10 seconds. It considers replies to Admin, immediate work and planned
work. Pulse itself is neither an LLM call nor a workflow. Classification emits
decisions; dispatch performs their effects and must avoid duplicate starts.

The supplied [GTD reference](https://cruciallearningindia.in/getting-things-done-gtd-what-it-is-and-how-it-works/)
describes capture, clarification, organization, reflection and engagement.
Sapiens adapts that idea to explicit software rules; the reference does not
specify a heartbeat algorithm. Concrete rules remain to be written.

Pulse may be **Vacant** or **Busy**. The notation provisionally means that the
tick selects no new execution or selects execution, respectively. Whether these
instead describe available Sapi capacity must be settled before implementation.
The pure `pulse` function takes rules as input; it is not a completed scheduler.

## Callbacks and workflows

Callback composes **Hook**, **Condition**, and **Reaction**. A reaction triggers a
workflow, creates Adhoc work, or retries a failed attempt within a limit.
Dismissal records a reason without launching work.

A workflow starts only through **Cron** or **Callback → Trigger**. Pulse can
admit that pending start without becoming another initiator. Retries preserve
the original origin. Manual requests and WBS output need routing through one of
these two paths; that routing is not yet selected.

- **Pipeline:** a workflow of scripts, with no LLM calls, including indirect ones.
- **Gantt:** a workflow using LLM and script steps; not merely a timeline view.
- **WBS:** creates or redesigns workload. Its outputs are tasks, workflow
  definitions, or further planned WBS work. It does not automatically start them.

Repairing a workflow creates a new fork and archives the original reversibly.
Prior definitions and execution history remain intact. Restoration must not
implicitly replay work. Archive timing, active runs and retargeting existing
Crons/callbacks remain decisions to make.

## Deliberately reduced scope

The old organization tree, specialized Agency taxonomy, Job/Cue/WorkGraph model,
mandatory task dates, and extensive run hierarchy are removed from this working
specification. This does not remove runtime code or stored data. The original
workspace artifact remains untouched.

Remaining design work is grouped into three responsibilities:

1. **Pulse:** ownership/scope, Vacant/Busy semantics, deterministic rules,
   priority, capacity, fairness and input that cannot be classified by rules.
2. **Reactions:** Cron alternatives, rule ordering, event deduplication,
   bounded retry/backoff and dismissal.
3. **Work redesign:** fork/archive lifecycle, active work, schedule retargeting,
   restoration, recursive WBS limits and Agile/Scrum terminology.

## Verification

The notation contains data declarations and one pure classifier wrapper. Text
leaves intentionally defer detailed schemas; comments specify constraints that
the types alone do not enforce. Compilation status is reported with the edit;
a type check would not establish scheduler correctness.

## Worked cases

Each case pairs a Mermaid diagram with Haskell-style descriptive notation:

1. [Domain brainstorming](cases/01-domain-brainstorming.md).
2. [Build and schedule a daily digest](cases/02-daily-digest.md).
3. [Instagram maintenance Project](cases/03-instagram-project.md).

The case fragments are an illustrative DSL, not compilable Haskell modules or
an implemented orchestration API. Constructors and record fields are shorthand;
they do not claim to type-check against SapiensSpecNotation.hs. Chief/Lead/Group
roles provide scenario context. Project, deadline policies, and orchestration
operations are proposed extensions; these examples do not silently add them to
the base module. No example is an instruction to execute external actions.

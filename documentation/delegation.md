# Delegation v1

This Python implementation follows the descriptive Haskell notation in
[PR #16's work model](specs/WorkGraph.md). Haskell remains specification notation;
Python owns this interim implementation. The separate language migration is not
part of this change.

```haskell
replMode =
  Call --> Triage --> (Outcome :& Reply)

execMode =
  Call --> Triage --> Execution --> (Outcome :| WorkGraph)

delegationMode =
  Call --> Triage --> Delegation --> execMode
```

Only the Outcome branch of Exec is enabled. No WorkGraph interpreter, task DAG,
WorkGraphMorphism, cron, or recurring triggers are implemented. A Call starts from
an explicit Admin request, clarification, explicit retry, or accepted handoff.
Tasks keep one accountable owner and retain their identity across calls.

## Decisions and prompts

| Runtime node | Prompt | Decision |
| --- | --- | --- |
| Assessing (Triage) | `decision-triage.md` | FitsSpecialization or OutsideSpecialization |
| ChiefTriage | `decision-chief-triage.md` | Work itself, SpecialistSelected, NewSpecialistNeeded, RequestUnclear |
| CreatingSapi | `decision-create-sapi.md` | Propose specialist identity; host observes SpecialistCreated |
| ReadyToWork | `decision-prepare-task.md` | Prepare the Task specification within Execution |
| Delegation | `decision-delegation.md` | Prepare the selected recipient's instructions/context |
| Execution | `decision-execution.md` | Work/tool choices, evidenced Outcome, or referral |

The transition table uses the state and event names in the PR. Chief performing
work itself follows the PR's prose: FitsSpecialization → ReadyToWork. Preparing
instructions at Delegation is an intermediate node before the recipient's new
Assessing call. Decision traces distinguish the conceptual transition `after`
from the controller's immediate `nextNode`. Task preparation is part of Execution,
not a fourth mode. WaitingForAdmin resumes ChiefTriage on an explicit clarification.

Each reached decision node invokes its named prompt and expects a validated JSON
response with an event, brief reason, and evidence. An immediate Repl answer fits
one model invocation; Exec and delegation use additional invocations for their
reached decisions. All invocations within one Call share its configured timeout.
Every decision receives the shared HTML wiki guidance and example path; only
Execution may read or update Notes.html. Invalid output fails visibly and requires explicit retry; it never silently chooses
a different route. Tool events remain in existing transcripts and activity logs.

Default templates live in root `prompts/`. Log → Edit decision prompts saves
Admin overrides under the data directory's `decision-prompts/`. An edit affects
the next invocation, including a later node of an already-running Call. The exact
rendered prompt, template path/hash, model/effort, response, evidence, host validation,
and accepted transition are archived under the Sapi's `decisions/<id>` archive.
These are inspection records, not private model chain-of-thought. Task data cannot
select arbitrary prompt files or install an override through host-control.

The host deterministically checks IDs, permissions, allowed routes, capacity,
deduplication, and decision shapes. These guards do not require model decisions.
Prompts guide an unrestricted local Codex process; they are not an OS sandbox.

## Routing and recovery

Supported routes are Admin → Sapi, Admin → Chief, Chief → Sapi, and Sapi → Chief.
The receiving Sapi performs its own Triage. Chief may create a specialist only if
Admin selected Allow creating a Sapi for the request; existing team tools remain
available for explicitly authorized team management during Execution.

There is one accepted outgoing handoff per Call. Busy/retired destinations reject
admission without transferring responsibility. A specialist already in the same
routing chain cannot be selected again; Chief may reassess a referral. The chain
is bounded to eight handoffs; exhaustion requires Admin intervention.

SQLite schema 4 prevents older hosts from silently ignoring delegation state.
The workloads table is authoritative for task specifications, calls, accepted
handoff intents, decision references, and outcomes. Recipient turns still use the
existing JSON conversation store. Save the handoff intent first with a stable
recipient Call ID, then submit idempotently and project the resulting turn to SQL.
Reconcile accepted calls on startup and after worker completion, without a timer
for Sapi work. A persisted projection or active JSON turn prevents duplicate
submission. Retirement and new chat admission respect accepted queued calls.

After restart, never-started accepted work resumes; previously running turns are
interrupted and require explicit Retry. Retry does not re-dispatch an already
accepted handoff or repeat a saved outcome. Stop between decisions prevents a new
handoff. An already accepted handoff has its own recipient Stop/Retry controls.
No claim is made that external actions execute exactly once or that Stop undoes
them. An Outcome must explicitly account for the task's completion criteria.

A returned specialist reply is attributed to that specialist in the original
chat. Chief is not automatically called to paraphrase it. Answer Chief resumes a
WaitingForAdmin workload with a new Call and preserved original intent.

## Tasks and YAML

Tasks displays a minimal clickable list with **Upcoming** and **Past** tabs.
Upcoming includes queued, running and waiting tasks. Completed, unresolved,
failed, interrupted and cancelled tasks appear in Past. Rows show the objective,
status and Sapi assignment; expanding a row shows the task specification as a
read-only YAML body, with Copy and a separate rendered result. Long YAML lines
wrap to fit the panel. Expanded rows persist while live state refreshes.

The selected Sapi sees tasks it owns or has participated in. Repl-only chat has
decision records in Log but does not add a Task. Exact prompts and Call lineage
remain available in Log and the complete YAML export; they do not fill the task
body. YAML is a presentation/export of authoritative structured data, not another
editable state store.

The small output-only YAML emitter supports exactly the JSON-shaped read model;
keys and scalars are quoted to preserve ambiguous strings and untrusted text.
There is no YAML parser or evaluator in the runtime and no additional production
package dependency. Independent parser round-trip checks use PyYAML in tests.
The browser inserts YAML task bodies with textContent, never HTML or Markdown.

API additions:

- `GET /api/agents/<id>/tasks`: complete application/yaml export, including prompts.
- `GET /api/agents/<id>/tasks?format=json`: compact list metadata and YAML specification bodies.
- `GET /api/agents/<id>/decisions`: all recorded decisions for that Sapi as YAML.
- `GET /api/decision-prompts`: current templates and editable paths.
- `PUT /api/decision-prompts/<node>` with `{ "content": "..." }`: override a known node.
- Messages accept `allow_create: true` and, for explicit clarification, `workload`.
- `delegate(decision)` admits only a recorded HandoffPrepared response belonging
  to the active caller. Caller/target lineage is host-owned, not arbitrary JSON.

## Verification

Run the Python suite and JavaScript checks from the repository root:

```sh
python3 -m pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -p 'test_*.py'
node tests/chat_links.test.cjs
node tests/workspace_merge.test.cjs
node tests/tasks.test.cjs
```

Delegation tests use deterministic providers and temporary state. They exercise
real host, runner, SQLite/JSON recovery, prompt records/edits, creation authority,
referral loops, clarification, cancellation, and HTTP/YAML boundaries without
paid model calls or access to live user data.

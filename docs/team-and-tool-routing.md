# Team creation and tool selection audit

## Findings

The host had a UI endpoint for agent creation (`Service.create_agent`), but no
`create_agent` operation in the agent-facing host-control manifest or dispatcher.
Asking the main Sapi to create a team could therefore produce a plan without
creating persistent agents through its supported tool.

Task assignment already supported a target, but starting that task did not.
Recurring-job creation and immediate runs also acted only on the caller.
A task with no due date remained planned unless separately started.

Tool-selection instructions contradicted one another. The operating policy
preferred APIs and local data, while the conversation and computer-use manifests
explicitly made Blindly4 the default for browser work.

An isolated live-model test exposed another issue: individually creating three
agents, assigning and starting tasks, and configuring a recurring job exhausted
the 16-call budget. Most side effects were saved, but the parent conversation
failed before delivering its completion report. Increasing the budget would hide
the avoidable round trips.

## Implemented changes

- The main Sapiens can call `create_agent` through the same validated HTTP
  host-control endpoint. Names and roles use existing validation. Matching
  name/role/manager requests reuse an agent; conflicts fail. New agents immediately
  receive their host-control configuration and reporting relationship.
- `run_task`, `recurring_job`, and `run_job` accept an assignee `target`.
- `task` accepts `start: true`, returning both saved task and queued run IDs.
- `batch` accepts up to 20 ordered operations. Later operations can target unique
  names created earlier. Nested batches and unknown fields are rejected.
  Failure receipts report the completed results and failed index. Earlier writes
  remain persisted: this is not a rollback transaction. Resume unsaved steps only.
- The main Sapiens is instructed to act on explicit team requests and implicit
  requests for distinct ongoing responsibilities, use existing suitable agents,
  assign real work, and distinguish queued work from verified completion.
  Ordinary multi-step tasks and hypothetical/quoted text do not authorize teams.
- Conversation and computer-use guidance consistently prefers sufficient evidence,
  available service tools/connectors/APIs, direct fetch/search, and then Blindly4
  when a suitable faster authorized route is unavailable. Agents must state the
  fallback reason, not infer a need for desktop automation merely from a URL.

## Verification

`tests/test_team_creation.py` exercises the real HTTP server and agent command,
three-agent creation, duplicate reuse, reporting relationships, assignment,
queued task execution, persistence across restart, recurring-job ownership and
single execution at a timer deadline. It also covers invalid creation, batch
execution, partial failures, and nested-batch rejection. The LLM used in these
regression tests is scripted; these tests prove host behavior, not language-model
intent classification.

Isolated live GPT-6 Sol/high checks use temporary app data, not the Admin's live
workspace. The API-route check fetched a fixture JSON service once, returned its
correct release name/date, and did not invoke the computer wrapper. The initial
implicit-team check exposed the tool-limit failure described above and prompted
the batch implementation. Repeating that implicit request after the change
completed successfully: three new owners, one queued task per owner, and one daily
recurring definition assigned to Writer. The reply accurately reported the recurring
job as `needs_strategy`; the smoke test did not execute real daily generations.
The full deterministic suite passed 112 tests.

## Boundaries and follow-up

Tool selection remains model policy, not a deterministic routing gate. A passing
example does not prove the model will choose correctly for every service or
prompt. The host inherits the tools exposed by its Codex process; it does not
inherit this desktop conversation's connected accounts or install connectors.
Never claim an unavailable integration was used.

For enforceable routing across providers, add a host-owned capability registry
(service, operations, availability/authentication, supported scope), adapters for
those capabilities, and a dispatcher that attempts a suitable direct route and
records a reason before granting UI fallback. Enforce this at the execution
boundary, not only in a prompt or wrapper that unrestricted shell can bypass.
Test unavailable connectors, insufficient scopes, stale data, login barriers,
rate limits, and visible-UI requests separately. Never treat fallback as permission
to bypass service access controls.

The deterministic recurring detector currently supports only a Blindly AX list.
Connector/event-feed detectors require adapters and their own bounded validation;
a recurring definition alone is not a functioning monitor. Fresh-generation
schedules use the existing `always` strategy with a generation justification.
Unsupported detectors must remain blocked, rather than turning into expensive
model polling. Cadence, authentication, and access requirements still need enough
information from the Admin to execute.

## Requests from other Sapis

Non-chief Sapis use `request_agent` with the proposed role, context, tasks and
recurring cadence. The host records the actual caller as origin and creates a
review task due now for the chief; busy chief work is respected by the scheduler.
Assignment notices in both chats mention the origin and recipient. A mention is
attribution, not dispatch: the saved task is the delivery mechanism.

The chief can use `dismiss_task` with a reason. The task is archived as dismissed,
a queued run is cancelled, and both chats receive the decision through task
activity. A running review can dismiss its own task and finish its reply.
Dismissal does not create an agent or falsely mark the requested work completed.

# Usage and watcher recovery

## Investigation

The WhatsApp setup interaction on 2026-09-16 executed 30 commands. It repeatedly
navigated Finder/Recent Items to launch the application, listed apps four times,
and requested overlapping accessibility trees (up to 2,000 nodes / depth 25).
The original Sapi prompt was 7,294 characters. Reprocessing accumulated tool
history across the session, rather than that prompt alone, explains the large
input-token total. Repeated commands are a diagnostic signal, not automatically
waste: refreshing an AX path before a mutation remains necessary.

Recorded provider usage: 1,044,280 input (978,560 cached), 3,063 output; 1,047,343
total. The SDK reserved 32,000 for the whole CLI session, but that session could
make many model/tool steps. It charged the raw total after completion, exceeding
the entire 1,000,000 weekly allowance. The immediately following learning job was
budget-blocked. The host then skipped the agent forever, including after a later
budget reset. Its saved recurring watcher had never run.

The director's status command returned its own empty recurring-job list while
omitting recurring jobs on team members. It incorrectly generalized this to all
Sapis. Team checks logged attention counts but did not deliver chat notices.

## Changes

- Per-Sapi **… → Token consumption**: rolling 1h / 24h / 7d totals, cached input,
  uncached input, output, recent calls, tool counts, output characters, repetition
  counts, and editable execution limits. Totals use call completion timestamps,
  not job creation time. Reasoning tokens are already part of output.
- Per-attempt files in each agent's `usage/` are authoritative; SQLite `usage_calls`
  is a rebuildable UI projection. Each retry gets a fresh record. In-progress,
  interrupted or otherwise unreported usage is explicitly unknown, never zero.
- One-time historical import reads archived usage; it cannot recover overwritten
  retries. Historical calls use the run's completion timestamp, or archive mtime
  if completion is unavailable. The UI discloses this limitation.
- Local budget units are uncached input + output + ceil(cached input / 10).
  This is a configurable-allowance product policy, not model pricing, a dollar
  estimate, or the user's subscription quota. Raw usage remains unmodified.
  Verified old cached charges are discounted exactly once; unknown charges stay.
- Default allowances: 1,000,000 units per weekly sprint, 100,000 per model call.
  Consolidation reserves three calls. Weekly reset uses the saved SDK calendar;
  the rolling seven-day usage view is independent of that reset.
- CLI tool output history is limited to 1,200 tokens; the computer wrapper also
  bounds returned content (4,800 characters by default) and marks truncation.
  Compact Blindly command metadata is cached by executable mtime. A launch-only
  helper uses `/usr/bin/open -a` with an argument array to avoid Finder navigation.
  All actual UI observations/mutations still use Blindly and its safety checks.
- Routine context includes the last five chat exchanges and five notes; full
  history remains persisted and available to memory consolidation. Each recurring
  run includes its own durable checkpoint and last result.
- A 120-second timeout and a stop after 16 completed tool steps bound sessions.
  These are operational bounds, not a strict token cap: provider usage arrives
  at turn completion, and a tool may already be running when an event is received.
  Failed/interrupted action runs are never automatically replayed. Unknown usage
  conservatively consumes the reserved allowance.
- Failed learning is isolated from interactive/recurring work. Budget-blocked
  never-started work is reconsidered when enough allowance is available. Budget
  enforcement still applies to every new admission.
- Team status includes each member's recurring definitions, health, last run and
  budget. Blocked/overdue/recovery notices are durable and deduplicated, delivered
  to the Sapi and its direct manager. A recovery notice means scheduling is
  available again, not that the task succeeded.
- `checkpoint` stores structured watcher observations, coverage and blockers
  before optional consolidation. It does not expire with the 90-second chat
  observation buffer. Job cards expose blockers and the latest checkpoint.

## SDK boundary

`SapiAgent` extends the pinned SDK runtime in the integration repository. Its
`_work`, `_reserve`, `_settle` hooks preserve flow/transaction semantics while
separating raw usage from budget units. Regression tests cover this dependency;
review these hooks when updating the SDK submodule. No submodule changes needed.

## Validation

Integration tests cover rolling boundaries, per-agent isolation, retries, unknown
usage, cache accounting, idempotent migration, budget recovery, failed learning,
team visibility, notification deduplication, durable checkpoints, and tool bounds.
The existing integration/SDK suites, browser settings workflow and a local Codex
CLI smoke test also run. No user messages or WhatsApp content are test fixtures.

Codex output-history setting:
https://learn.chatgpt.com/docs/config-file/config-reference#tool_output_token_limit

## Live verification

The existing watcher recovered with its original ID and completed its first
scheduled run. Consolidation completed first. The watcher used 13 tool steps,
403,829 input tokens (377,344 cached) and 1,685 output tokens: 405,514 raw tokens
and 65,905 budget units. It saved a partial-coverage checkpoint and notified its
manager instead of claiming complete DM coverage. This differs from the initial
setup interaction and is not a controlled before/after benchmark.

A later refinement compacts tree JSON into labeled rows with original AX paths,
omitting repeated geometry metadata. Mutation receipts also omit unrelated team
history. Failed watcher attempts persist their last three bounded tool results,
so a manual recovery can inspect prior observations without treating them as
current UI state. The implementation preserves Blindly's fresh-path requirement.

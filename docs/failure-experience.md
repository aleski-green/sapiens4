# Execution failures must inform the next attempt

A research task can fail before returning an answer. Previously, that left an archived error and a short-lived observation cache, but no procedural failure evidence in the next conversation or the memory consolidation input. Retrying after the observation freshness window could repeat discovery without recognizing the earlier failure.

The host now includes up to ten per-agent execution failure records in an `execution-experience` manifest. Each record contains a job reference, timestamp, flow, terminal status and bounded classifications. It excludes raw commands, credentials, page content and arbitrary error text. Historical timeout errors are classified without migrating state. Newly observed Blindly workflow/permission errors are retained in the existing run archive and job state, even when later tool calls evict them from the observation cache.

This is historical procedural evidence, not proof of current access or task completion. Fresh UI observations still expire normally. The model must verify changed prerequisites and must not reuse old selectors or lease tokens. Successful recovery does not erase the fact that a route encountered a failure; the record also retains the final job status.

Memory consolidation receives the same manifest. Its fingerprint includes this evidence, so failure changes invalidate the previous consolidation fingerprint. Learning jobs are excluded from the failure evidence to avoid feedback from learning's own failures. The existing consolidation flow decides what to retain; this change does not add an automatic model call after every failure or guarantee that the model follows a learned lesson. Evidence remains bounded by the retained job history.

## Workflow lease handling

Blindly's global `--lease` parameter is not part of individual command usage strings in the compact schema. An agent could acquire a lease, omit it from subsequent commands and receive `workflow_busy` for its own lock. Invented environment variables do not supply the token.

The wrapper now records a successful explicit acquisition against the current execution clock, forwards that token to subsequent wrapper calls (including reads), and attempts release on normal return, error or timeout. It does not steal another execution's lease or override an explicit `--lease` argument. Cleanup failure produces a warning; service lease expiration remains the fallback for a host crash or unavailable service. Calls outside an active host execution retain raw CLI behavior and must pass `--lease` explicitly.

## Research routing

A URL alone no longer implies desktop automation in the conversation instructions. Prefer available search, direct retrieval or an authorized API for public research. UI automation remains available for tasks requiring rendered content or an authorized session. A retrieval denial does not establish that signing in will solve it. Stop blocked routes and ask for source text when evidence cannot be obtained.

## Further work

These changes repair lease propagation and missing failure input, not every cause of an unproductive run. Follow-up work should add an enforced discovery budget with deterministic partial-result recovery, progress-aware termination, richer task-scoped evidence and verified lesson outcomes, and typed capability routing with explicit access/coverage results. Any proposed general circuit breaker must distinguish repeated failed observations from legitimate pagination and must allow artifact saving after discovery stops.

## Validation

Regression tests cover failed-run evidence across restart, per-agent isolation, classification persistence, bounded and sanitized evidence, fingerprint changes, lease forwarding and timeout cleanup, and rejection of a previous execution's lease. Tests use mocked provider and subprocess behavior; live LinkedIn access is not part of the acceptance test.

## Research completion follow-up

Research/writing instructions now explicitly use evidence → draft → identify gaps. Complete UI extraction is not a prerequisite for a qualified replacement draft. Identity must still be supported, assumptions disclosed, and missing original text acknowledged.

The computer wrapper enforces a per-execution live discovery budget: at most 12 live read calls, ending after half the call allowance or 120 seconds, whichever is sooner. Parallel calls share a locked counter. A fresh execution resets it; expired execution records cannot grant more access. Cached snapshot pagination, host-control artifact saving and lease release remain available. The guard returns a structured `discovery_stopped` receipt rather than continuing UI exploration. It does not constrain every possible shell command or web-search provider; it is a host wrapper guard, not a security sandbox.

The finish phase reserves up to 90 seconds (one third of the call allowance). If the model still hits its execution limit after a discovery stop without saving an artifact, the host returns an explicit incomplete result and missing-source guidance, never a fabricated draft or success claim. Existing saved-artifact recovery remains intact.

The default server no longer silently caps an agent's setting at 300 seconds. An explicitly supplied `--timeout` remains a server cap; the settings UI reports the current effective timeout. This is independent of the UI discovery budget, so a larger call allowance does not grant unlimited UI scanning.

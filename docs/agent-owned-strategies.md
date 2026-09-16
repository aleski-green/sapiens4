# Agent-owned execution strategies

## Responsibility

A Sapi owns the method, not just the response. The shared operating policy tells
it to define evidence of success, reuse sufficient fresh observations, prefer
cheap targeted reads, and turn repeated work into reusable automation. It saves
concise decisions, not private reasoning. The director sees subordinate health
and blockers without needing to repeat their scans.

The host provides observation primitives, measured cost, persistence, and limits.
It does not decide which chats matter or whether a preview satisfies the user's
goal. Those are the Sapi's decisions, with coverage limitations made explicit.

## Lifecycle

- New or materially changed recurring definitions require a strategy. A Sapi can
  save the definition and strategy in the same conversation. Otherwise an enabled
  job receives one bounded `strategy` turn at its next scheduled time.
- The Sapi saves `approach`, `success`, `scope`, `expected_units`, and `watch` using
  `host-control strategy`. The strategy is bound to its goal, interval, and watch
  configuration. Renaming or pausing does not invalidate it.
- A change-driven plan must pass a real read-only observation test before becoming
  ready. The test checks accessibility and shape; it does not prove semantic
  coverage or future success. The Sapi supplies that interpretation.
- Generative work needs a saved `generation_reason`. The prompt forbids using this
  mode to bypass change detection. This is an agent instruction; the host validates
  a nonempty justification, not its truth.
- Unsupported capabilities or access blockers produce a saved blocked strategy.
  Returning prose without saving a plan also blocks. Timers do not keep trying.
- Routine calls receive their strategy, checkpoint, and three recent cost/outcome
  records. Unrelated chat, accumulated notes, task comments and peer job plans are
  omitted from automated prompts. Targeted host status remains available.
- Checkpoints carry `outcome: useful | no_change | blocked` and are bound to the
  current run. A successful provider response alone does not acknowledge a change
  or record goal success. A current `ok` checkpoint with `useful` or `no_change`
  can acknowledge the baseline; only `useful` records `last_success`.
- Cost above the Sapi's estimate, two repeated tool calls in a run, or two runs
  with no useful/known outcome suspend routine execution for strategy review.
  Cost/tool counts are measured; usefulness remains the Sapi's assessment, not an
  independent semantic evaluator. The Sapi revises the plan or names a blocker.

## Bounds

Automatic planning is limited to one setup per definition revision, one review
per job per rolling day, and two planning calls across an agent's jobs per rolling
day. These calls also obey normal budget, tool and timeout limits. A failed or
incomplete setup stops for explicit repair instead of renewing its allowance each
day. Attempt history survives goal changes and restarts; enqueue/save gaps are
recovered from SDK job keys.

Paused jobs remain paused. **Plan now** explicitly retries setup/review without
resuming the timer; ready jobs offer **Run now**. Explicit user-requested calls use
normal budget admission. Neither automatic planning nor watcher calls may trigger
consolidation. Budget totals and historical usage are preserved.

## Current capability boundary

The timer currently supports the existing deterministic Blindly AX-list probe,
with Sapi-selected observed identifiers, scope, cadence and wake limits. It does
not execute arbitrary Sapi-authored programs or subscribe to arbitrary APIs. The
Sapi can develop local scripts during authorized interactive work, but must report
an unsupported timer capability instead of claiming such a script is scheduled.
This change adds agent-owned planning and feedback around the supported execution
primitives; a general sandboxed script/plugin registry is separate work.

Existing plans must go through this lifecycle when next enabled/due. Akira's
existing paused job is preserved, and no new strategy is manually chosen for it.

## Verification

The deterministic integration suite exercises agent setup through real host-control
operations, observation validation, zero-model unchanged polls after setup,
blocked/incomplete setup, budget and pause gates, restart/enqueue recovery,
planning limits, cost-triggered review, outcome feedback, and policy injection.
The provider is simulated: these checks establish host behavior, not that a live
model will always choose an optimal strategy. No paid model run is needed to
validate the state machine.

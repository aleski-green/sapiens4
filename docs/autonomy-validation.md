# Recurring execution reliability

A verified useful run must leave the next occurrence runnable. Model completion,
saved strategy and delivery are separate facts.

## Runtime behavior

- Cost estimates and repeated-command counts remain visible efficiency feedback.
  They do not suspend verified useful work. Missing outcomes, interrupted actions
  and execution warnings still require reconciliation before another attempt.
- Planning retains the pending occurrence. Planning calls do not consume execution
  cooldowns or daily execution capacity, including when a plan changes wake limits.
  A blocked occurrence does not hold up other ready jobs, and later reviews receive
  distinct run IDs while retaining the original occurrence.
- Successful admission advances from the scheduled anchor. Downtime produces one
  catch-up and an explicit receipt for coalesced slots, never a burst of old sends.
- Learning processes bounded experience batches, commits its cursor with the memory
  patch, and resumes remaining batches after restart. It excludes tool manuals,
  retrieves a bounded relevant memory subset, and reserves space for later debate
  stages. Original history and unrelated memory remain intact.
- Finished repair runs are excluded from subsequent task context. An executing
  task may request completion, applied only after successful execution. Managers
  can review and close their subordinates' completed work.
- New chief Sapis monitor their teams by default. Existing monitoring preferences
  are preserved. Reviews have eight tool calls for evidence and bounded delegation;
  they cannot authorize external sends, replay uncertain actions or increase budgets.
- `job_diagnostics` exposes occurrences, planning, checkpoints and feedback together.
- Settled run history is archived before the active-state byte limit is reached.
  Pending jobs, task references and the latest full learning receipt are retained.

No Telegram behavior or selectors were added to core prompts or Blindly4.

## Deterministic autonomy regression

Run `python3 -m unittest discover -s tests -p 'test_autonomy.py' -v`.

The independent scripted sink asserts one delivery per due occurrence, rather than
accepting the agent's own checkpoint as the oracle. The suite exercises 300 consecutive
six-hour occurrences, deliberately low cost estimates, repeated verification reads,
ten host restarts, initial planning, review admission caps, policy changes, downtime,
stopped external work, legacy state recovery, 1,000 memory experience records, task
closure, and chief-led repair through the actual worker queue. Scripted model answers
test runtime mechanics; they do not establish a model's success probability.

## Opt-in real-agent UI benchmark (macOS)

This uses the installed Codex model and Blindly4 against a dedicated local Cocoa app.
The app independently appends deliveries to a ledger and rebuilds its controls after
each send. The harness checks exact recipient, unique content, count, matching
checkpoint, ready strategy, and absence of a duplicate after each host restart.
It admits work through scheduler ticks, never through `run_job`.

```sh
mkdir -p .test-output
xcrun swiftc tests/fixtures/AutonomyFixture.swift -o .test-output/AutonomyFixture
python3 scripts/benchmark_autonomy.py --fixture .test-output/AutonomyFixture --cycles 3
```

Use a compatible explicit `-sdk` path if the local compiler and default SDK differ.
The harness packages the executable as a macOS app so frontmost-process guards can
validate it. Accessibility permission is required. It creates an isolated CORPORA,
consumes real model usage, and briefly operates the local fixture window; it never
uses the production recipient or production runtime data. Evidence is retained in
the printed `.test-output/autonomy-live/...` directory.

The six-hour timer is accelerated. This is an end-to-end smoke test, not a 72-hour
soak or proof of Telegram reliability in every UI state. No success is claimed if
the independent ledger or post-action checks fail.

## Qualification on 2026-09-25

- Main regression suite: 156 tests passed, including 300 scheduled occurrences and
  ten restarts, bounded learning over 1,000 experience records, and chief-led repair.
- Pinned runtime: 25 tests passed. Frontend: two tests and syntax validation passed.
- Blindly4 self-test and native navigation/readiness checks passed; its code is unchanged.
- Real-agent native UI: three consecutive scheduled cycles passed in 253.92 seconds,
  with a host restart after each cycle and zero extra deliveries. Setup used an
  autonomous planning call; execution was admitted only through timer ticks.

| Cycle | Independently recorded deliveries | Tool calls | Repeated commands | Checkpoint / strategy |
| --- | ---: | ---: | ---: | --- |
| 1 | 1 | 13 | 2 | ok/useful / ready |
| 2 | 2 | 9 | 3 | ok/useful / ready |
| 3 | 3 | 10 | 3 | ok/useful / ready |

The live runs used guarded paste and exact-draft guarded button presses. The agent
rediscovered changed control paths, verified the visible outgoing item and empty
draft, and retained a runnable strategy despite cost-estimate and repetition warnings.
The independent ledger contained three different messages to the test recipient.

Initial fixture trials stopped safely when app activation or native paste support
was absent. Another trial exposed planning being counted as an execution wake when
the plan changed wake limits; the runtime fix has its own regression test. These
failed trials are not counted as successful cycles. Production Telegram and a
real-time six-hour/72-hour soak were not exercised by this qualification.

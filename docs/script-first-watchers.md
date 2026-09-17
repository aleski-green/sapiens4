# Script-first recurring watchers

## Why the budget was still draining

The previous change bounded each model session but did not change the execution model. Every timer still started the model, even when the relevant inbox had not changed. Akira's saved prompt also explicitly requested `consolidate` on new observations. Similar previews, outgoing messages and group activity repeatedly became reasons for additional reasoning.

On September 16, after the previous recovery, the saved provider records show:

| Flow | Model calls | Raw tokens | Local budget units |
| --- | ---: | ---: | ---: |
| Scheduled watcher | 8 | 2,006,868 | 382,090 |
| Consolidation | 18 | 409,370 | 201,671 |

Raw totals include cached input, and local units are the app's allowance policy, not money or the provider's subscription limit. The 249,600 remaining local units could admit a one-step call, but not a three-step consolidation requiring a 300,000-unit reservation. This explains the budget-blocked consolidation despite a nonzero balance.

## New execution model

1. Following the [agent-owned strategy lifecycle](agent-owned-strategies.md), a Sapi discovers an app's stable chat-list container once with Blindly and saves a structured `watch` plan through `recurring_job`.
2. A deterministic host script polls with two read-only commands: `apps` and a bounded `tree`. No model, app activation, navigation, message sends, or generated shell code is involved.
3. The script extracts the configured list's direct conversation rows and optionally filters exact chat names. It ignores menu trees, the opened conversation, selection, geometry and relative clock labels.
4. The first observation establishes a baseline without a model call. Unchanged checks also use no model calls. Only changed previews can admit agent review.
5. Pending changes wait for sufficient model budget and the configured cooldown/hour/day limits. Defaults: 30 minutes between admissions, two per rolling hour, eight per rolling day. Existing runs count when a legacy job receives its first plan.
6. A completed review with a matching successful checkpoint acknowledges the observed baseline. Failed/interrupted actions need explicit review; the timer does not replay them. Observation errors retain the baseline and back off up to an hour without asking a model to rediscover the same blocker.

Model runs receive the changed names and previous checkpoint, without unrelated chat history or accumulated timer notes. Phone-number-labelled candidates come first; that label is not proof of contact or DM status. The model must verify relevance and incoming-message status before claiming an update.

Watchers cannot request consolidation while executing: the host rejects it and tells them to save a checkpoint. Explicit MindMap consolidation and the existing daily learning schedule remain available. A script poll creates neither a model job nor a new memory note.

Unconfigured jobs receive one bounded Sapi-owned strategy turn before routine execution. Incomplete setup then stops for explicit repair. A deliberately generative recurring job can select `mode: always`; wake limits still apply. For ready strategies, explicit “Run now” bypasses change detection and time-based wake limits, while normal SDK budget admission still applies.

## Configuration

```json
{
  "op": "recurring_job",
  "id": "existing-job-id",
  "watch": {
    "mode": "changes",
    "probe": {
      "bundle_id": "net.whatsapp.WhatsApp",
      "container_id": "ChatListView_TableView",
      "names": []
    },
    "cooldown_minutes": 30,
    "max_per_hour": 2,
    "max_per_day": 8
  }
}
```

The two identifiers above were observed in the current WhatsApp installation; other apps need their own verified identifiers. This is a constrained chat-list script, not a universal script runner. Sapis choose and persist the plan; the host executes the reviewed implementation. Empty `names` watches the visible list; populated `names` requires every selected chat to be visible. Configure this under Jobs → Edit. Application/list identifiers are under Observation plan.

Settings under “…” now have Profile, Schedule, Memory, Usage and Limits tabs. Edits persist when switching tabs and save together. Keyboard arrows, Home and End navigate tabs; invalid fields reveal their tab.

## Coverage and limitations

The detector reads visible AX list previews. It cannot promise complete DM coverage, classify all non-contacts, inspect archived/off-screen messages, or detect an intermediate message that arrived and vanished between polls. Closed apps, missing containers, absent selected chats and truncated trees are reported rather than treated as an unchanged inbox. A changed preview is a candidate for review, not proof of a new incoming DM. Scroll/filter changes can also surface new candidates; wake limits bound the resulting reasoning.

The host serializes these reads with other computer work; busy work can delay checks. Provider usage is still reported at the end of a model call, so this does not create a hard provider-token cap. It removes the model from the unchanged polling path instead.

## Validation and local recovery

- Integration tests cover zero-call unchanged polling, restart persistence, changed-only admission, rolling limits, budget recovery, error backoff, scope filtering, missing/truncated observations, failed-review baseline retention, legacy admission history and consolidation rejection.
- Browser checks verified tab separation, cross-tab editing/saving, usage display, and watcher-plan editing.
- Two real read-only WhatsApp script checks produced `baseline` then `unchanged`, with zero model calls and unchanged budget. This validates the unchanged path, not a complete DM-monitoring claim.
- Akira's existing job was configured with the observed list identifier. Its paused state and run history were preserved. Its prompt now focuses on changed incoming DMs and durable checkpoints. The obsolete budget-blocked consolidation was cancelled; historical usage was not reset.
- A full local data backup was taken before the migration.

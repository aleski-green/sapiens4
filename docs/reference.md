# Usage and operations

See the [README](../README.md) for startup and platform requirements.

## Work and conversations

ChiefSapi manages the team and can delegate to specialists. Specialists can refer
work to Chief; accepted handoffs retain task identity and return the responsible
Sapi's result to the original chat. When Chief needs clarification, it asks in the
chat; answer there like any other message.
Creating a Sapi or Group does not itself start work.

Personal Tasks offers Upcoming and Past, with read-only YAML specifications and
results. Scheduled routines can be created, edited, paused and resumed through
Chief. Group tasks have shared ownership, revision checks and explicit execution;
saving or restoring a task does not run it. Groups require at least two active
members and one Lead, with up to eleven active memberships per Sapi.

Each Sapi or Group has its own chat, files, Notes and browser workspace. Group
chat defaults to the Lead; explicit mentions address members. Personal and other
Groups' histories remain separate. Retirement and archival preserve saved data.

Stop terminates the runner and child commands but cannot undo completed external
actions. Never-started queued work resumes after restart; previously running work
becomes interrupted and requires explicit retry. Inspect uncertain external
outcomes before retrying. The shared computer allows one owner at a time.

## Notes and files

Memo reads `workspaces/<id>/Notes.html`. Its wiki has `about`, `map` and `content`
sections; about/map enter model context and the model reads relevant content as
needed. Store media as separate files. Link to them from Notes.html with a relative workspace
path or an HTTP(S) URL. Inline images and data URLs are unsupported.

A restored tab loads its native browser view the first time it becomes visible. After an uninterrupted hour in the background, Workspace can release a local read-only text preview with an existing file and no back or forward history. Its tab, bookmark and zoom remain in the owning Sapi's workspace. Selecting it reloads the file from disk and can reset its scroll position. Websites, HTML documents, media and pages of unknown type keep their views.

Native desktop tabs open websites, local files and bookmarks. Text/source files
render literally; HTML, PDF and media use the native browser. Closing a tab does
not delete its file. Remote clients can preview text files and control the host's
tabs, but do not stream native browser views.

Local Workspace windows receive change notifications over a same-origin WebSocket and fetch a snapshot when needed. A hidden window disconnects and catches up when shown. While the socket is unavailable, unchanged snapshots double the HTTP polling interval up to 10 seconds. Changed content, clicks and keystrokes reset it to 750 ms. Socket retries start at 2 seconds and double up to 30 seconds. Remote relay connections keep their existing refresh behavior.

## Configuration

Default model: `gpt-6-sol`, reasoning `high`; Deep work uses `xhigh`. A call's
30-minute limit is shared across its decision steps. Environment overrides:

| Variable | Purpose |
| --- | --- |
| `SAPIENS_DATA_DIR` | Data directory |
| `SAPIENS_PYTHON` | Python executable |
| `SAPIENS_CODEX_BINARY` | Codex executable |
| `SAPIENS_CODEX_MODEL` | Model |
| `SAPIENS_CODEX_REASONING_EFFORT` | Reasoning effort |
| `SAPIENS_BLINDLY_BINARY` | Blindly4 executable |

Decision templates live in `corpora/prompts/`. **Edit decision prompts** saves local
`decision-prompts/*.md` overrides for subsequent invocations; past decision
records retain the prompt they used. Context, Usage and legacy budget settings
are inactive. Global Codex configuration is unchanged.

## Data and updates

macOS/source data defaults to `.sapiens4` in the checkout; Windows packages use
`%LOCALAPPDATA%\Sapiens4`. Back up the complete data directory while the host is
stopped, including:

- `corpora.sqlite3`: agents, workloads, Groups, preferences and attachments.
- `agentpy/`: persisted chat state and archives; the legacy path remains in use.
- `workspaces/`: Notes, files and deliverables.
- `decision-prompts/`: local prompt overrides.
- `corpora-identity.json`, registry and remote credential files: identity and trust.

A database-only backup is incomplete. Protect backups as credentials and private
data. Copying a backup retains its corpora identity; it does not create an
independent corpora or synchronize simultaneous hosts. Never run two hosts against
one data directory. Install new versions manually using the platform setup guide.

The header corpora picker changes the viewed workspace; Pause and Activate control
execution separately. Drafts and layout are stored on the viewing device. Cached
remote snapshots are read-only until reconnection. See [remote setup](remote.md)
for pairing, revocation and relay deployment.

## HTTP API

The host binds to loopback. Writes require JSON and `X-Sapiens-Local: 1`;
a supplied Origin must match the loopback Host. Common entrypoints:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health`, `/api/state` | Readiness and current state |
| WebSocket | `/api/host/corpora/<id>/api/updates` | Current revision on subscribe and after local changes. Compare with `updates_revision` in the state response. |
| POST / PUT | `/api/agents`, `/api/agents/<id>` | Create/update Sapis |
| POST | `/api/agents/<id>/messages`, `/api/agents/<id>/attachments` | Submit chat or attachments |
| GET | `/api/agents/<id>/notes` | Memo and file metadata |
| GET | `/api/agents/<id>/tasks` | YAML export; `?format=json` returns task metadata |
| GET | `/api/agents/<id>/decisions` | Decision records |
| POST | `/api/agents/<id>/control` | Authorized team/workspace operations |
| POST | `/api/agents/<id>/turns/<id>/retry`, `/api/agents/<id>/turns/<id>/cancel` | Explicit recovery |
| GET / PUT | `/api/decision-prompts`, `/api/decision-prompts/<node>` | Inspect/edit templates |

Group notes, messages, attachments, tasks and calls use `/api/groups/<id>`.
Updates require the relevant revision. [RSpec scenarios](../spec) exercise the
public contracts; see [Testing](testing.md) to run them.

### Model configuration drafts

`GET /api/model-settings-draft` reads the corpora's saved configuration draft.
Without a saved file it returns revision 0, Codex `gpt-6-astra` / `medium`, and no
per-Sapi overrides. This is the Sapiens4 recommendation, not the CLI catalog's
default. Reading does not create a file or change execution settings.

`PUT /api/model-settings-draft` accepts the same object:

```json
{"revision":0,"defaults":{"provider":"codex","model":"gpt-6-astra","effort":"medium"},"overrides":{}}
```

Overrides are keyed by Sapi ID and contain complete provider/model/effort choices.
Omitting an override restores inheritance. Saves validate the current Codex catalog
outside the service state lock, then check the revision and Sapi identities under
the lock and atomically replace `model-settings-draft.json`. The response contains
the incremented revision. A stale revision returns 409 without overwriting the
saved draft. Invalid models/efforts or unsupported providers return 400; discovery
failures leave the previous draft intact. Both Codex and Claude selections are supported.

The draft endpoint remains inactive and is not consumed by execution.

### Applied model settings

The Sapi customization page explicitly distinguishes inherited settings from a
full per-Sapi override. It displays the global provider/model/effort summary and
explains that removing inheritance creates settings for that Sapi only. Re-enabling
inheritance removes the override on save. This presentation change does not enforce
one provider per corpora or migrate existing mixed-provider configurations.
Sapi, model and effort pickers share a themed, bounded list. Arrow keys, Home/End
and initial-letter navigation move focus; Enter/Space selects, Escape cancels,
and Tab leaves the picker. Clicking outside dismisses the list. Picker state is
local to the dialog and never enters the saved settings payload.

The Models dialog has Global settings and Sapi customization pages sharing one
unsaved draft. Page navigation does not write settings. Save and apply saves both
pages together; closing without saving discards pending edits. The selected page
is presentation state and is not persisted in the settings payload.

Feedback is derived from that draft: saving, invalid selections, unsaved changes,
or saved settings. Invalid selections identify Global settings or
the affected Sapi even when that selection is on the other page. Successful-save
feedback does not depend on the application's transient toast timer when reopening
saved settings. A successful Save and apply closes the native modal before showing
the confirmation toast. It rises from the bottom center, outside the blurred
backdrop, and respects reduced-motion settings. The footer
contains only Save and apply; the top-right close control dismisses unsaved edits.
Failed saves keep the dialog and pending edits open, with revision-conflict and
provider errors visible in the dialog.

The Models screen now uses `GET /api/model-settings` and `PUT /api/model-settings`
with the same object shape and validation rules. **Save and apply** atomically
writes `model-settings.json`, using an independent revision counter. Until this
file exists, GET offers any previous draft for review at revision 0, and execution
continues using the existing environment defaults and Normal/Deep mode. Opening
the dialog never activates a draft.

After applying, each new run uses its Sapi override, or the corpora default when
no override exists. The selected effort is explicit and supersedes Normal/Deep;
Deep does not silently change it to an unsupported effort. Configuration is
resolved once under the service lock when a run starts. Every provider invocation
and decision audit record in that run uses the captured model and effort, even
if settings are saved between decision steps. Queued work, retries and delegated
runs resolve the current settings when their new run starts. This does not pin a
whole Routine or workload across multiple runs or restarts.

Saving validates the catalog outside the service lock. Execution does not launch
catalog discovery or silently fall back to a different model on provider failure.
Existing Codex command permissions are unchanged. AgencyKind overrides remain subsequent work. Catalog entries advertise choices;
they do not guarantee account authorization for an eventual model call.


### Claude provider

`GET /api/providers/claude/models` obtains the installed CLI catalog through its
streaming control initialization, without submitting a user prompt. Discovery uses
safe mode with tools and MCP integrations disabled, a 30-second deadline, bounded
responses and process cleanup. Entries use `resolvedModel` where available;
duplicate aliases are collapsed. Effort choices come from the advertised metadata.
An empty effort string means the Claude provider default; the CLI receives no
`--effort` flag. Models without effort metadata expose only this default.

The product recommendation is `claude-opus-5-5` with `medium`, enabled only when
that exact model and effort appear in the catalog. It is independent of the CLI's
changing `default` or `opus` aliases. Mixed-provider defaults and per-Sapi overrides
are supported, with each required provider validated once per save.

Execution uses the existing Sapi workspace, prompt, run identity, process deadline
and cancellation handling. Claude runs with `--print --output-format stream-json
--verbose --no-session-persistence --dangerously-skip-permissions`, an explicit
model, and an effort flag only when configured. Only a successful terminal result
completes the decision; intermediate text and error results cannot count as
success. Decision records include the provider as well as the model and effort.
The existing noninteractive permission policy is retained; read-only remains
outside this change.

`SAPIENS_CLAUDE_BINARY` overrides executable discovery. Otherwise it searches PATH,
the native user installation and, on Unix, NVM installations. Windows requires a
native executable. This integration does not install Claude or change login state.
Model discovery does not prove that a subscription can execute a model. Tests use
isolated simulated providers; live account behavior requires a separate smoke test.

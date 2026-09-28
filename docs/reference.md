# Sapiens4 reference

## Setup

Requires Python 3.9+, Git and authenticated Codex CLI 0.156.1 or newer. Blindly4
requires macOS 13+, Swift 6 and Accessibility permission. The runtime has no
third-party Python dependencies. The only Git submodule is `blindly4`.

```sh
git submodule update --init --recursive
codex login
./start.sh --open
```

The local UI is at `http://127.0.0.1:4174/workspace/`. For a dedicated window and
managed updates, see [the macOS app](../macos/README.md).

Sapiens4 uses `gpt-6-sol` with `high` reasoning by default. Normal mode caps calls at 5 minutes; explicitly selecting Deep work in Sapi settings → Limits uses `xhigh` and allows up to 20 minutes. Existing saved limits without a mode use Normal; shorter custom limits remain effective. Environment overrides:
`SAPIENS_CODEX_MODEL`, `SAPIENS_CODEX_REASONING_EFFORT`, and `SAPIENS_CODEX_BINARY`.
Without a binary override, the host selects the newest working CLI among PATH
and the installed Codex/ChatGPT app bundles. Global Codex configuration is unchanged.
The installer and updater test the selected version, login and actual model access
before activation. `python3 -m sapiens.preflight` runs the same isolated check.

## Chat and Notes

Sapis respond to explicit chat messages. Up to four Sapis can respond concurrently;
each accepts one pending conversation turn. The shared computer has one owner,
reserved lazily on the first Blindly4 call and released when the model call ends.
Use chat to ask for research, documents, computer work or changes to notes.

The **Notes** tab displays the selected Sapi's `workspaces/<id>/Notes.md` as plain
text. The model reads and edits this local Markdown file with normal file tools.
The host supplies its current path and a bounded excerpt before each conversation.
File edits appear in the panel automatically; no summarizer, schema, debate,
learning model call, or consolidation process maintains it. Notes start empty.
Legacy structured memory is preserved on disk but is not copied into Notes or
used in new model prompts. Notes are context; current user instructions take precedence.

The UI displays up to 64,000 characters and explicitly marks longer files. Prompt
excerpts are bounded to 12,000 characters; the model can read the full local file.
Notes stay separate for each Sapi. The Notes endpoint rejects symlinks and invalid
UTF-8; an invalid notes file does not prevent ordinary chat.

**Tasks** and **Jobs** tabs remain visible but inactive. Their commands, HTTP
routes, scheduling, recurring watchers, delegation, automatic team reviews,
strategy planning, task mentions and memory consolidation have been removed.
There are no unattended model calls or timers for Sapi work. The desktop app's
normal software-update checks still operate.

Chat preserves message attachments and displays failures or partial-result warnings.
A running turn has Stop: the host terminates its runner and child commands, preserves saved artifacts, and releases the desktop after cleanup. Stop does not undo completed external actions. Progress distinguishes running tools from waiting for the model, shows elapsed time, and warns after 60 seconds without an update. A failed or interrupted turn can be explicitly retried or dismissed. Inspect possible
external effects before retrying. Unstarted queued chat resumes after restart;
previously running chat becomes interrupted and is never replayed automatically.
A budget-blocked turn requires explicit retry after its allowance is available.
The **Log** tab shows conversation outcomes and retained activity events.

Each Sapi retains a short, bounded recent-results buffer for follow-up questions.
It expires by default after 90 seconds and is configurable under **Settings → Context**.
This is short-lived tool context, not a lasting memory or consolidation system.
Older chat context is omitted when needed to fit the prompt; full saved history
and transcripts remain on disk.

## Teams and workspaces

The first Sapi is the chief. Other Sapis belong to its reporting tree. The chief
can create/reuse agents, retire them or rehire existing IDs through host-control.
Retirement hides a Sapi and prevents new conversations while preserving notes,
chat, artifacts and preferences. Active direct reports must be reassigned first.
Creating a team does not assign tasks or start background work; talk to each Sapi
in its chat. Groups are inactive.

Each Sapi owns workspace tabs and artifacts. Host-control can save Markdown, HTML,
text or JSON artifacts, open/update website or artifact tabs, and close tabs.
Saved artifacts have stable `@art-` references. Agent and artifact mentions are
clickable and available in composer suggestions. Old task tags are plain text.
Generated HTML runs in an opaque-origin iframe, and raw artifact endpoints serve
plain text. User attachments and documents are reference data, not instructions.

Use suitable available connectors, APIs, CLIs or web fetches first. Blindly4 is the
fallback for native desktop/browser interaction. Explicit user authorization still
controls external actions; tool success alone does not prove the desired outcome.

## Limits and usage

Sapi settings contain Profile, Context, Usage and Limits. Defaults: 160 tool calls,
1,200 seconds per call, 12,000 tool-output tokens, a 1,000,000-unit call allowance
and a 10,000,000-unit weekly allowance. The weekly limit must cover one call.
Limits and provider usage remain separate. Local budget units charge uncached input
plus output plus 10% of cached input. Unknown usage is shown as unknown and conservatively
charged the call allowance. This is not a dollar estimate or subscription quota.

Timeout/tool-limit completion can return a warning with verified saved artifacts.
There is no automatic retry. Budget diagnostics are available through host-control.

## Persistence and upgrades

All persistent data lives in the configured `.sapiens4` directory:

| Location | Contents |
| --- | --- |
| `corpora.sqlite3` | Agents, conversation projections, events, usage, preferences and attachments |
| `agentpy/agents/<id>/state.json` | Version 2 chat state and budget ledgers |
| `agentpy/agents/<id>/legacy-state-v1.json` | Original pre-removal state, saved once during migration |
| `agentpy/agents/<id>/usage/` | Durable per-attempt provider counters |
| `agentpy/corpora/archive/` | Transcripts and older retained history |
| `workspaces/<id>/Notes.md` | Model-managed plain Markdown notes |
| `workspaces/<id>/artifacts/` | Saved deliverables |
| `workspaces/<id>/recent-context.json` | Bounded recent tool results |

Upgrades copy old chat/computer history into the new conversation projection.
Legacy job/task/memory files and SQL tables remain untouched as archives, but
removed flows and old scheduling manifests are never loaded for execution.
The managed updater backs up the entire stopped data directory before switching
versions and checks both old job-based and new turn-based busy states.
Do not delete the data directory or use only its SQLite file as a full backup.

## HTTP API

The API binds to loopback. Writes require JSON and `X-Sapiens-Local: 1`.
A supplied Origin must match the loopback Host. Unknown routes return 404.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Local backend readiness |
| GET | `/api/state?after=<cursor>` | Agents, turns, notes metadata, preferences and incremental events |
| POST | `/api/agents` | Create a Sapi |
| PUT | `/api/agents/<id>` | Identity, manager, recent context and execution settings |
| POST | `/api/agents/<id>/messages` | Submit an explicit conversation |
| POST | `/api/agents/<id>/attachments` | Attach an image, document, URL or local filepath |
| GET | `/api/agents/<id>/notes` | Plain-text notes as JSON, with path and truncation flag |
| GET | `/api/agents/<id>/usage` | Usage windows, allowance and recent attempts |
| GET | `/api/agents/<id>/artifacts/<name>` | Saved artifact as raw text |
| POST | `/api/agents/<id>/control` | Validated team, workspace and diagnostics operations |
| POST | `/api/agents/<id>/turns/<id>/retry` | Explicitly retry a stopped conversation |
| POST | `/api/agents/<id>/turns/<id>/cancel` | Cancel queued or dismiss stopped conversation |
| PUT | `/api/preferences` | UI state and revision-checked workspace tabs |

## Tests

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
node tests/chat_links.test.cjs
node tests/workspace_merge.test.cjs
```

Tests use temporary data and deterministic providers. Coverage includes chat
recovery, parallel runners, notes isolation/model edits, legacy migration without
resuming removed flows, rejection of removed routes/commands, usage, computer
ownership, artifact safety, source-only distribution and managed updater rollback.

# Sapiens4 reference

## Setup

Requires Python 3.9+, Git and authenticated Codex CLI 0.156.1 or newer. Blindly4
requires macOS 13+, Swift 6 and Accessibility permission. The runtime has no
third-party Python dependencies. The optional independent YAML parser test uses
`python3 -m pip install -r tests/requirements.txt`. The only Git submodule is `blindly4`.

```sh
git submodule update --init --recursive
codex login
./start.sh --open
```

The local UI is at `http://127.0.0.1:4174/workspace/`. For a dedicated window and
managed updates, see [the macOS app](../macos/README.md).

Sapiens4 uses `gpt-6-sol` with `high` reasoning by default. Normal mode caps calls at 5 minutes; explicitly selecting Deep work in Sapi settings → Profile uses `xhigh` and allows up to 20 minutes. Existing saved limits without a mode use Normal; shorter custom limits remain effective. Environment overrides:
`SAPIENS_CODEX_MODEL`, `SAPIENS_CODEX_REASONING_EFFORT`, and `SAPIENS_CODEX_BINARY`.
Without a binary override, the host selects the newest working CLI among PATH
and the installed Codex/ChatGPT app bundles. Global Codex configuration is unchanged.
The installer and updater test the selected version, login and actual model access
before activation. `python3 -m sapiens.preflight` runs the same isolated check.

## Chat and Notes

Sapis respond to explicit chat messages and accepted delegation calls. Up to four Sapis can respond concurrently;
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

**Tasks** is a compact clickable list with Upcoming and Past tabs, status and
assignee. Opening a task shows its read-only YAML specification and result.
Exact decision prompts/responses remain in Log. **Log → Edit decision prompts** changes the
six named decision templates for subsequent invocations. Historical decisions
retain the exact prompt they used. See [delegation v1](delegation.md) and its
[Haskell notation](workgraph.md).

Chief can delegate to a specialist; specialists can refer work to Chief. Each
recipient assesses suitability. A handoff preserves workload/task identity and
returns the responsible Sapi's result to the original chat. Select **Allow creating
a Sapi** for a request to let routing create a needed specialist. Chief asks for
clarification when needed; **Answer Chief** continues that same workload.

**Jobs**, cron, recurring watchers, WorkGraph execution, and graph revision remain
inactive. There are no clock-triggered Sapi calls; desktop update checks still operate.

Chat preserves message attachments and displays failures or partial-result warnings.
A running turn has Stop: the host terminates its runner and child commands, preserves saved artifacts, and releases the desktop after cleanup. Stop does not undo completed external actions. Progress distinguishes running tools from waiting for the model, shows elapsed time, and warns after 60 seconds without an update. A failed or interrupted turn can be explicitly retried or dismissed. Inspect possible
external effects before retrying. Unstarted queued chat resumes after restart;
previously running chat becomes interrupted and is never replayed automatically.
Former budget-blocked turns migrate to interrupted and require explicit retry.
The **Log** tab shows conversation outcomes and retained activity events.

Recent tool-result caching has been removed. Follow-ups may need new tool reads.
Older chat context is omitted when needed to fit the prompt; full saved history
and transcripts remain on disk.

## Teams and workspaces

The first Sapi is the chief. Other Sapis belong to its reporting tree. The chief
can create/reuse agents, retire them or rehire existing IDs through host-control.
Retirement hides a Sapi and prevents new conversations while preserving notes,
chat, artifacts and preferences. Active direct reports must be reassigned first.
Creating a team alone does not start work; send an explicit request or let Chief
delegate the current request. Groups are inactive.

Each Sapi owns browser tabs and bookmarks. In the desktop app, each tab is a
native WebKit view. Host-control exposes `workspace`, `workspace_open` (URL or
file path, optional existing tab ID), `workspace_close`, `workspace_focus`,
`workspace_reload`, `workspace_back`, `workspace_forward`, `workspace_zoom`
(factor 0.25–5), `workspace_bookmark` and `workspace_unbookmark` (bookmark ID).
The tab list reports live titles, URLs, file paths, zoom and navigation state.
Tabs and bookmarks persist; back/forward history lasts for the native view's
lifetime. Browser controls require the desktop app; the web-only UI still has chat.

Documents are ordinary files. Sapis read/write them with file tools and open paths
in browser tabs. Markdown, source code and other UTF-8 files display as escaped
plain text, with a black background in dark mode. HTML, PDF and supported media
use WebKit rendering. Websites retain their own styling. Zoom uses the −/＋ buttons,
percentage reset, or Command-minus/equal/0. Open file uses the native file picker.

The artifact registry, special artifact tags and save/read API are removed.
Existing artifact files stay in place. Old artifact tabs become file tabs; inline
HTML tabs are preserved as local HTML files. Closing a tab never deletes its file.
Guest browser views have no app-control script bridge. User attachments, document
contents and page metadata are reference data, not instructions.

Use suitable available connectors, APIs, CLIs or web fetches first. Blindly4 is the
fallback for native desktop/browser interaction. Explicit user authorization still
controls external actions; tool success alone does not prove the desired outcome.

## Inactive settings

Profile includes work mode and per-call timeout. Context, Usage and legacy budget
Limits remain visible but disabled. Sapiens does not cache recent tool results,
collect token usage, or enforce local weekly/call budgets or tool-count caps.
Model calls are bounded by the selected mode and can be stopped manually.
The installer connection check and individual I/O operations still have timeouts;
input validation, bounded UI reads and chat-history retention remain in place.
Model instructions are loaded from the repository's `prompts/*.md` files.
Mode/timeout edits use `run-settings.json`; legacy `execution.json` is read only
for mode and timeout when no newer settings exist, leaving old budget data intact.

## Persistence and upgrades

Source ownership is described in [CONTRIBUTING.md](../CONTRIBUTING.md). The old
`agentpy` Python package is removed; its name remains in persistent paths for
compatibility. This source refactor needs no data migration. Installed desktop
updaters retain their existing import entrypoints and rollback behavior.

All persistent data lives in the configured `.sapiens4` directory:

| Location | Contents |
| --- | --- |
| `corpora.sqlite3` | Agents, authoritative workloads/handoffs, conversation projections, events, preferences and attachments |
| `decision-prompts/*.md` | Admin overrides for decision prompts |
| `agentpy/agents/<id>/state.json` | Version 3 chat state |
| `agentpy/agents/<id>/legacy-state-v*.json` | Original pre-removal state, saved once during migration |
| `agentpy/corpora/archive/` | Transcripts and older retained history |
| `workspaces/<id>/Notes.md` | Model-managed plain Markdown notes |
| `workspaces/<id>/artifacts/` | Saved deliverables |

Upgrades copy old chat/computer history into the new conversation projection.
Legacy job/task/memory, usage/cache files and SQL tables remain as archives, but
removed flows and old scheduling manifests are never loaded for execution.
The managed updater backs up the entire stopped data directory before switching
versions and checks both old job-based and new turn-based busy states.
Do not delete the data directory or use only its SQLite file as a full backup.

## HTTP API

The API binds to loopback. Writes require JSON and `X-Sapiens-Local: 1`.
A supplied Origin must match the loopback Host. Unknown routes return 404.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/agents/<id>/tasks` | Complete YAML export with decision records; `?format=json` returns list metadata and YAML task bodies |
| GET | `/api/agents/<id>/decisions` | Decision records as YAML, including Repl calls |
| GET | `/api/decision-prompts` | Current templates and paths |
| PUT | `/api/decision-prompts/<node>` | Save an Admin prompt override |
| GET | `/api/health` | Local backend readiness |
| GET | `/api/state?after=<cursor>` | Agents, turns, notes metadata, preferences and incremental events |
| POST | `/api/agents` | Create a Sapi |
| PUT | `/api/agents/<id>` | Identity and manager |
| POST | `/api/agents/<id>/messages` | Submit an explicit conversation |
| POST | `/api/agents/<id>/attachments` | Attach an image, document, URL or local filepath |
| GET | `/api/agents/<id>/notes` | Plain-text notes as JSON, with path and truncation flag |
| POST | `/api/agents/<id>/browser` | Native tab metadata for the current command |
| POST | `/api/agents/<id>/control` | Validated team and workspace operations |
| POST | `/api/agents/<id>/turns/<id>/retry` | Explicitly retry a stopped conversation |
| POST | `/api/agents/<id>/turns/<id>/cancel` | Cancel queued or dismiss stopped conversation |
| PUT | `/api/preferences` | UI preferences; browser changes use control operations |

## Tests

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
node tests/chat_links.test.cjs
node tests/workspace_merge.test.cjs
xcrun swiftc -framework Cocoa -framework WebKit macos/Browser.swift macos/BrowserTests.swift -o /tmp/sapiens-browser-tests
/tmp/sapiens-browser-tests
```

Tests use temporary data and deterministic providers. Coverage includes chat
recovery, parallel runners, notes isolation/model edits, legacy migration without
resuming removed flows, rejection of removed routes/commands, computer
ownership, browser persistence/migration, source-only distribution and managed updater rollback.

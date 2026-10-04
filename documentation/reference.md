# Sapiens4 reference

## Setup

Requires Python 3.9+, Git and configured Kimi Code CLI (K3). Blindly4
requires macOS 13+, Swift 6 and Accessibility permission. The runtime has no
third-party Python dependencies. The optional independent YAML parser test uses
`python3 -m pip install -r tests/requirements.txt`. The only Git submodule is `blindly4`.

```sh
git submodule update --init --recursive
kimi login
./start.sh --open
```

The local UI is at `http://127.0.0.1:4174/workspace/`. For a dedicated window and
managed updates, see [the macOS app](../macos/README.md).

Sapiens4 defaults to the Kimi harness, model alias `kimi-for-coding`, and `high` effort.
Configure that alias in Kimi Code CLI or set `SAPIENS_KIMI_MODEL` to your K3 alias.
Set `SAPIENS_HARNESS=codex` before starting the host to select Codex instead
(default model `gpt-6-sol`). Normal mode uses `high`; Deep work requests `max`
for Kimi or `xhigh` for Codex. The installed Kimi CLI/provider must support the
requested effort; unsupported values may fall back to its model default.
Every Sapi call has one 30-minute execution limit shared across decision steps;
legacy saved timeout values are ignored.

`SAPIENS_HARNESS_MODEL`, `SAPIENS_HARNESS_REASONING_EFFORT` and
`SAPIENS_HARNESS_BINARY` override the selected adapter. Provider-specific
`SAPIENS_KIMI_*` and `SAPIENS_CODEX_*` settings also work. Codex selects the newest
working CLI among PATH and installed Codex/ChatGPT bundles when no override is set.
The installer and updater probe the selected harness and actual model access before
activation. Codex additionally checks its minimum version and login status.
`python3 -m sapiens.preflight` runs the same isolated check.

## Chat and Notes

Sapis respond to explicit chat messages and accepted delegation calls. Up to four Sapis can respond concurrently;
each accepts one pending conversation turn. The shared computer has one owner,
reserved lazily on the first Blindly4 call and released when the model call ends.
Use chat to ask for research, documents, computer work or changes to notes.

Each Sapi maintains `workspaces/<id>/Notes.html`, an HTML wiki with exactly three
top-level `<section>` elements in order: `about` (identity and purpose), `map`
(internal links with short descriptions), and `content` (anchored knowledge articles).
Only about/map enter call context; each is omitted if longer than 12,000 characters.
The model reads relevant content from the file and decides to update or keep it
intact before replying. It reads the full file before an atomic edit. The prompt
is in `prompts/notes-wiki.md`, shared by conversation and delegation prompts.
Only Execution may read or update wiki files during delegation; assessment uses
the supplied about/map context. No separate generation or consolidation call runs.

Use `<pre><code class="language-yaml|python|html|svg|haskell">` with one language
per block. YAML carries structured knowledge, Python script examples, HTML/SVG
visuals, and Haskell descriptive workflow notation (never executed). Scripts live
in their own `.py` files, linked from the wiki. Prose is minimal; operating rules,
raw logs, and secrets do not belong in Notes. Current requests take precedence.

The Notes panel shows only the wiki, with about/map above independently scrolling
content. It highlights snippets in both themes and supports tables, inline SVG,
embedded images, and workspace-relative PNG/JPEG/GIF/WebP files up to 10 MB. The
renderer copies an allowlist of inert elements and attributes, removing scripts,
event handlers, forms, frames, custom styles, and remote image loads. Links open
through the existing workspace controls; internal links navigate within content.

First use imports existing YAML (or Markdown if YAML is absent) as escaped snippets;
original files remain intact and existing HTML is never overwritten. Notes are
separate per Sapi. Invalid UTF-8, missing files and symlinks produce a Notes error
without blocking chat. Legacy memory is not imported or included in prompts.

**Tasks** is a compact clickable list with Upcoming and Past tabs, status and
assignee. Opening a task shows its read-only YAML specification and result.
Exact decision prompts/responses remain archived. **Local workspace → Edit decision prompts** changes the
six named decision templates for subsequent invocations. Historical decisions
retain the exact prompt they used. See [delegation v1](delegation.md) and its
[Haskell notation](specs/WorkGraph.md).

Chief can delegate to a specialist; specialists can refer work to Chief. Each
recipient assesses suitability. A handoff preserves workload/task identity and
returns the responsible Sapi's result to the original chat. Only Chief can create
a needed specialist; no per-message permission is required. Chief asks for
clarification when needed; **Answer Chief** continues that same workload.

**Jobs**, cron, recurring watchers, WorkGraph execution, and graph revision remain
inactive. There are no clock-triggered Sapi calls; desktop update checks still operate.

Chat preserves message attachments and displays failures or partial-result warnings.
A running turn has Stop: the host terminates its runner and child commands, preserves saved artifacts, and releases the desktop after cleanup. Stop does not undo completed external actions. Progress distinguishes running tools from waiting for the model, shows elapsed time, and warns after 60 seconds without an update. A failed or interrupted turn can be explicitly retried or dismissed. Inspect possible
external effects before retrying. Unstarted queued chat resumes after restart;
previously running chat becomes interrupted and is never replayed automatically.
Former budget-blocked turns migrate to interrupted and require explicit retry.
The former Log tab and incremental activity feed have been removed. Existing activity history is left on disk; chat continues to show progress, outcomes and errors.

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
| `corpora.sqlite3` | Agents, authoritative workloads/handoffs, conversation projections, preferences and attachments |
| `decision-prompts/*.md` | Admin overrides for decision prompts |
| `agentpy/agents/<id>/state.json` | Version 3 chat state |
| `agentpy/agents/<id>/legacy-state-v*.json` | Original pre-removal state, saved once during migration |
| `agentpy/corpora/archive/` | Transcripts and older retained history |
| `workspaces/<id>/Notes.html` | Model-managed HTML wiki |
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
| GET | `/api/state` | Agents, turns, notes metadata, preferences and live activity |
| POST | `/api/agents` | Create a Sapi |
| PUT | `/api/agents/<id>` | Identity and manager |
| POST | `/api/agents/<id>/messages` | Submit an explicit conversation |
| POST | `/api/agents/<id>/attachments` | Attach an image, document, URL or local filepath |
| GET | `/api/agents/<id>/notes` | Complete HTML Memo as JSON, with path and available file metadata |
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
# DOM tests require Node.js 18 or newer.
npm install --prefix tests
node tests/notes.dom.test.cjs
xcrun swiftc -framework Cocoa -framework WebKit macos/Browser.swift macos/BrowserTests.swift -o /tmp/sapiens-browser-tests
/tmp/sapiens-browser-tests
```

Tests use temporary data and deterministic providers. Coverage includes chat
recovery, parallel runners, notes isolation/model edits, legacy migration without
resuming removed flows, rejection of removed routes/commands, computer
ownership, browser persistence/migration, source-only distribution and managed updater rollback.

The Memo tab renders one scrolling wiki article with a Sapi infobox, contents and
linked topics. Older YAML facts and collapsed topic trees remain readable without
rewriting source memory. Empty schema fields form a compact stub. Source file
modification time is shown; creation time and author remain unrecorded for legacy
files that have no provenance record. Optional `Notes.history.json` records document
creation and a SHA-256-bound author attribution; later untracked edits never inherit
the previous revision’s author. The file remains `Notes.html` for compatibility.

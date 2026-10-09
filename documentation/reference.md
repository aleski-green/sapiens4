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

Sapiens4 uses `gpt-6-sol` with `high` reasoning by default. Every Sapi call has one 30-minute execution limit, shared across its decision steps. Normal mode uses `high`; Deep work in Sapi settings → Profile uses `xhigh` with the same time limit. Legacy saved timeout values are ignored, and the CLI has no separate observation cutoff. Environment overrides:
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
delegate the current request. Groups add nonexclusive shared workspaces (see below).

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

## Groups

Each Group has at least two active Sapis and exactly one Lead. Sapis can join or
lead up to 11 active Groups (archived memberships do not count). Chief creates and archives Groups and transfers leadership;
Chief and the Lead manage membership. The sidebar + opens Chief with an editable
creation request; Sapi and Group creation both go through Chief. Existing profiles
and memberships remain editable in settings.
Removing a member requires reassigning unfinished tasks and finishing/cancelling
pending Group calls. Active Group members cannot be retired until removed.

Chat / Work / Updates are available for both Sapis and Groups; personal Work
uses the same Tasks, Automation and Memo navigation as Group Work. Group Chat defaults to the Lead; explicit @mentions or
a target ID address members directly. A Lead's reply can mention members to call
them. Each member is called at most once per originating request, and member
replies do not automatically fan out. Busy recipients wait in a durable queue.
Shared conversation context excludes personal chats and other Groups' histories.
Messages and uploaded attachments belong to the Group and retain their authors.

Chat / Work / Updates remain visible as split tabs: the label opens the default
view and its chevron opens a menu. Work defaults to Tasks, with Automation and
Memo in its menu; Automation offers Workflows. Chat offers Pins, Threads, Comments
and Add feedback (an editable chat draft, never automatically sent). Pins, Threads,
Comments and Workflows are explicitly unavailable until their backing features ship.
Updates offers Runtime, Events and a reserved Archived view. Memo reads Notes.html from
the shared Group workspace; Tasks holds revisioned shared tasks. Active, Done and
Deleted are options in the header filter. Sapi tasks use Upcoming and Past. Automation is reserved for the upcoming implementation. Members contribute autonomously; the
Lead can edit, assign or delete tasks while others are executing. Run task queues
the current task revision for its assignee. Saving a task alone does not execute
it. Personal Work shows the same task, not a copy. Revision conflicts require a
fresh read. Late results remain visible but cannot overwrite newer tasks or undo
a deletion. Deletion and Group archival are reversible; restoration never runs
work. Archival cancels unstarted calls and lets active execution finish.

Group browser tabs and files have their own workspace. Members use workspace_*
with a group ID to manage the shared browser. Updates record contributions,
leadership/membership changes, task edits, execution outcomes and archives.
Compact colour labels sit between each Sapi name and its activity time. They show
the Group initial (with a star for its Lead) and overlap as memberships grow, hiding initials when space is
too tight. Header labels retain full Group names beside the Sapi name. Opening a
Group highlights the Groups tab in pink and scopes the sidebar to its Lead and
members, showing their titles. Clicking a member opens the Group chat with their
@mention prefilled and preserves any drafted message. Clicking All, Sapis
or Groups exits to Chief, with Groups returning to the Group list. The Group avatar uses the Lead's
kaomoji with vertical member-color strips, Lead first. The shuffled remaining
order and label identity are persisted independently of leadership changes.

Group list rows show the name with a member-count chip and one preview line. The
header shows the name and about text. Groups is disabled when no active Groups
exist. Archive restoration is available through Chief.

Group API: GET /api/groups/<id>/notes (including relative images), POST /api/groups, GET/PUT /api/groups/<id>, POST messages/attachments,
POST tasks, PUT tasks/<id>, POST tasks/<id>/run, and POST calls/<id>/retry or cancel
under /api/groups/<id>. Updates require revision; task operations use the task's
revision. Host-control exposes group_create/get/update/message and
 group_task_create/update/run. SQLite schema 5 adds Groups and Group attachments
without rewriting existing Sapi records.

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

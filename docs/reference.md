# Sapiens4 reference

A local workspace for persistent Sapis. **CORPORA** provides the interface,
**AgentPy** runs the agents through your authenticated **Codex CLI**, and
**Blindly4** is the main tool for computer and browser interaction on macOS.

## Start

Requirements: Python 3.9+, Git, an authenticated Codex CLI, and macOS 13+ with
Swift 6 for Blindly4. Chat also runs on Linux. There are no third-party Python
or frontend package dependencies in the integration.

```sh
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
./start.sh --open
```

Open **http://127.0.0.1:4174/workspace/**. The first launch creates one real Sapi
without making an LLM call. Use **＋** beside CORPORA to create more.

`start.sh` initializes the pinned submodules, builds Blindly4 on macOS, and
starts the Python server. Subsequent Swift builds are incremental. To run an
already prepared checkout directly:

```sh
python3 -m sapiens --port 4174
```

If you need to sign in, run `codex login`. Sapiens4 uses your existing Codex
authentication and model settings. On macOS it compares the installed PATH CLI
and CLIs bundled with Codex/ChatGPT, choosing the highest installed version;
this avoids using an older npm CLI with a model supported by the desktop app.
To choose explicitly, set `SAPIENS_CODEX_BINARY=/absolute/path/to/codex` before
starting. No global Codex settings are changed.

## First iteration

- Create and rename individual Sapis; their name and role become runtime manifests.
- **Chat** runs a conversation with host commands for schedules, manager assignments,
  task creation/completion, team status and memory consolidation. Changes must be
  confirmed by the host before the Sapi acknowledges them.
- Chat also handles explicitly requested computer work through Blindly4. For
  example: “Use Blindly4 to list the open apps.” There is no mode selector.
- The **＋** menu attaches an image, document, link, or local filepath. Uploads
  accept files up to 10 MB, with up to eight attachments per message. Images
  support PNG, JPEG, GIF and WebP. Uploaded files are stored locally; Codex reads
  them when needed for the request. Links and filepaths are references.
- **… → settings** edits the name, role, manager, check interval, pause state and
  team monitoring. Status, next/last check and memory count live there.
- Names start with A–Z, followed by letters, numbers, or `- _ . : # + | ( ) & $ ^`.
  Spaces are not allowed; the limit is 24 characters. The UI offers three name
  suggestions at a time, equally drawn from masculine, feminine and neutral
  pools inspired by fiction, thinkers, founders and nature. Avatars are randomly
  generated and saved; existing duplicate faces are repaired on startup.
- Typing `@` opens keyboard-accessible suggestions for Sapis and named tasks;
  group entities will appear when group workflows are enabled. Enter/Tab selects
  a suggestion, arrows move, and Escape closes it. Task links open the assignee's
  task card, including completed tasks in Past.
- Task mentions use `@task-x0012:readable-name`: a unique random lowercase letter
  and four digits identify the task. The readable name starts with a–z, uses the
  same allowed characters as Sapi names, and allows up to 64 characters. Names
  generate from the title if omitted. The short `@task-x0012` also resolves.
  Rename active or completed tasks in their dialog; ordinary renames retain the
  tag and old mentions remain valid. Existing tasks migrate on startup.
  Host `task` accepts `target` (Sapi name/ID) for delegation. Assignment notices
  persist atomically with tasks and appear from the assignee in both chats.
- The last five chat/computer interactions retain timestamped tool observations
  in each Sapi's workspace. Each turn stores up to 6,000 characters of recent
  tool data (4,000 per result), with explicit truncation markers. Follow-ups reuse
  these observations; fresh state is still required before computer mutations.
  Background jobs do not evict this buffer. Reuse expires after 90 seconds by
  default; each Sapi's settings can disable it or change the window (1–3600 seconds).
  Explicit refresh/current-state requests bypass reuse within that window. This
  is separate from lasting memory.
- **MemX** (Memory Explorer), between Jobs and Log, shows the selected Sapi's consolidated `memx`
  in CORPORA's searchable JSON tree. **Start consolidation** waits for the runner,
  updates the tree, and shows **Done** only after learning succeeds. Click Done to
  run it again; failures expose Retry/Dismiss. Its state survives reloads.
  Explicit consolidation waits for active work but can proceed past unrelated
  failed runs. It does not retry those runs or resume unrelated budget-blocked work.
  The Jobs tab counter counts saved recurring definitions.
- **Tasks** holds one-off work: create a planned task, set an optional due time,
  start it, review its result, then mark complete. Completed tasks move to **Past**.
  Due tasks are admitted independently of periodic checks, including when checks
  are paused. A busy runner, stopped work or a sleeping/offline host can delay them.
  Task links open a dialog with result, comments, lifecycle activity and execution
  logs. Start/result/failure updates also appear in chat. New tasks execute a
  single task role that returns the requested result.
- **Jobs** holds recurring definitions with an interval, next-run time, last status,
  pause/resume, edit and run-now controls. **Past** contains finished runs. The
  existing agent check is shown as a built-in recurring job.
- **Log** shows one chronological activity history, including chat turns; it has
  no ongoing/past switch.
- **Log** shows real runtime events and Codex command/tool activity, polled every 750 ms.
- Retry failed, interrupted, conflicting or budget-blocked jobs; dismiss stopped
  jobs or cancel work that is still queued. Running calls finish or hit their deadline.
- Per-Sapi browser tabs, drafts and panel preferences persist in SQLite.

Groups, shared boards, and group workflows are the next iteration. Their simulated controls are disabled/hidden in this application.
No prototype messages, fake execution timers or sample attachments are used.

### Agent orchestration

Try “Wake up every 5 minutes and check tasks and other Sapis,” or tell Nova
“Your manager is Sapi-TheFirst.” The saved interval and reporting relationship
appear in **… → settings**; **Tasks** shows one-off work and **Jobs** shows recurring work. Use unique names or IDs when assigning managers.
The first Sapi is the main orchestrator and can never have a manager. New Sapis
report to it automatically; an optional manager can place a new Sapi deeper in
the tree. Missing parents, self-management and cycles are rejected. Clearing a
non-main manager returns that Sapi to the main orchestrator. Old disconnected
roots are repaired at startup.

Recurring jobs have independent intervals of 1–10080 minutes. Create them in
Jobs or ask in chat; their saved instructions run once per interval through the
serialized SDK worker. Run now preserves the next scheduled deadline. After
downtime, each overdue job gets one catch-up run, not a burst. Failed or
interrupted runs require review/retry/dismissal before that Sapi resumes work.
Definitions and run references persist in `agentpy/agents/<id>/recurring.json`.

Each Sapi defaults to a 10-minute local check. Ask to change the interval or
pause checks. The timer uses AgentPy's `tick()` to dispatch due reasoning tasks
and daily memory consolidation. It also inspects team job/task progress when
requested. An unchanged idle check makes no model call. “Consolidate your
memory” requests a learning pass after the current conversation finishes.
Learning retains the SDK's proposer/critic/arbiter validation. Automatic
self-modification is not enabled by this host.

Checks require the server to remain running and the computer to be awake.
A busy or stopped Sapi is deferred; missed intervals produce one catch-up check.
Stopped jobs are never automatically retried by the timer. A due task runs once;
its result appears in Tasks and chat, and completing the task requires a separate
verified completion. Team status distinguishes completed jobs from proven task
success. The reporting tree is metadata, not an authorization boundary.

Host scheduling settings live atomically in `agentpy/agents/<id>/host.json`;
manager links use the SDK's existing directory. SQLite remains a UI projection.
The host-control command uses the same validated loopback HTTP API as the UI.

### Computer access

Blindly4 needs macOS Accessibility permission for the terminal or application
hosting the server. If needed, run:

```sh
./blindly4/.build/release/blindly4 request-permission
```

Enable the host in **System Settings → Privacy & Security → Accessibility**.
Missing permission is reported by the computer task; the app does not grant
permission automatically. A completed job means its agent flow returned a reply;
read that reply to see whether the requested action succeeded. The computer card shows build/ownership status, not
a claim that Accessibility permission has been granted.

All jobs are serialized by this server, including jobs from different Sapis.
Only one unresolved job per Sapi is accepted. Computer ownership represents
this server's execution queue; it does not lock out other desktop applications
or independently launched agent processes. The inherited Codex execution
backend runs local tools without sandboxing. Blindly4 guidance preserves its
PID, fresh AX path and exact-draft checks. Ordinary chat permits only the local
host-control command; this distinction is behavioral, not an OS sandbox.

The embedded workspace tabs remain CORPORA's sandboxed browser frames. They
are separate from the native desktop that Blindly4 operates. Websites that
disallow framing can be opened with the tab's external-link button.

## Repository structure

```text
sapiens4/
  lab-corpora-ui/       # Git submodule: original CORPORA shell, styles, workspace tabs
  lab-sapiens-rnd/      # Git submodule: persistent AgentPy orchestration and Codex backend
  blindly4/            # Existing Git submodule: native macOS computer-use CLI
  sapiens/             # Local HTTP API, SDK adapter, SQLite projections, static asset seam
  web/                 # Live behavior adapter for the CORPORA interface
  tests/               # Integration tests using the real SDK and scripted workers
  start.sh
```

Each submodule is pinned to a commit; upstream sources are unmodified. The
parent repo holds Git links rather than copies of their source/history or
compiled binaries. `sapiens/assets.py` checks the small frontend loading seam
and appends the live adapter. If an upstream update changes that seam, startup
fails explicitly instead of silently reverting to demo behavior.

## Storage and recovery

Default local data lives in gitignored `.sapiens4/`:

| Path | Owner and purpose |
| --- | --- |
| `corpora.sqlite3` | UI profiles, projected messages/job results/events, browser tabs, drafts and panel preferences; attachment metadata and original message text; schema version 2, SQLite WAL |
| `agentpy/agents/<id>/` | AgentPy's existing atomic JSON state, manifests, budgets and run locks |
| `agentpy/corpora/` | AgentPy's shared artifacts, directory, mailboxes, receipts and archives |
| `workspaces/<id>/` | Working directory for that Sapi's Codex calls and generated files |
| `agentpy/agents/<id>/task-activity.json` | Durable task comments and lifecycle updates |
| `workspaces/<id>/recent-settings.json` | Per-Sapi recent-memory enablement and freshness interval |
| `workspaces/<id>/recent-context.json` | Last five interactive calls, bounded tool observations and answer excerpts; isolated per Sapi |
| `uploads/<id>/` | Local image/document uploads referenced by chat |
| `host.lock` | Prevents two Sapiens4 servers from running the same data directory |

**SQLite is for the UI application only.** AgentPy state remains authoritative
for jobs and agents' internal state. Projection updates are replayable and
deduplicated by runtime event sequence. The UI cannot change runtime state by
writing preferences. Back up the entire data directory while the server is
stopped; the SQLite database alone is not a backup of agent memory/state.

On restart, unstarted queued jobs resume. Previously running calls become
`interrupted`; they are never automatically replayed. Inspect the result of a
computer action before choosing Retry, because it may already have had effects.
Stopping the server waits for a current Codex call to finish; the default call
deadline is 300 seconds. Use `--timeout 120` to shorten it.

To choose another local store:

```sh
python3 -m sapiens --data-dir /path/to/local-data --port 4175
```

The server binds only to `127.0.0.1`, with no login. Host and Origin checks,
JSON-only mutation requests with a custom header, and an explicit public-asset
allowlist prevent unrelated websites or embedded guests from driving the API.
There is no LAN/public hosting mode in this iteration.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Server health |
| GET | `/api/state?after=<event-id>` | Agent/job projections, preferences, computer ownership and up to 500 newer events |
| POST | `/api/agents` | Create `{name, role, color?, face?}` |
| PUT | `/api/agents/<id>` | Update `{name, role, manager?, schedule?}` while idle |
| POST | `/api/agents/<id>/messages` | Submit `{text, attachments?: [id, ...]}`; legacy `flow` is still accepted |
| POST | `/api/agents/<id>/attachments` | Upload `{kind, name, data: base64}` or reference `{kind, value}` |
| POST | `/api/agents/<id>/control` | `{op: "status", "schedule", "manager", "task", "run_task", "finish_task", "recurring_job", "run_job", or "consolidate", ...}` |
| PUT | `/api/agents/<id>/tasks/<task>` | Rename `{name}`; readable name or explicit full tagged name |
| GET | `/api/agents/<id>/memory` | Selected Sapi's consolidated `memx` JSON |
| POST | `/api/agents/<id>/jobs/<job>/retry` | Explicit retry |
| POST | `/api/agents/<id>/jobs/<job>/cancel` | Cancel queued/dismiss stopped work |
| PUT | `/api/preferences` | Save UI preferences only |

Writes require `Content-Type: application/json` and `X-Sapiens-Local: 1`.
Event responses include `cursor` and `latest_cursor`; request the returned
cursor again until caught up. Runtime and SQLite data paths are never served
as static files.

## Verify

```sh
python3 -m unittest discover -s tests -v
(cd lab-sapiens-rnd && python3 -m unittest test_runtime test_adversarial test_codex_process -v)
swift run --package-path blindly4 blindly4 --self-test
swift run --package-path blindly4 blindly4 schema
```

The integration tests exercise real AgentPy persistence with scripted LLMs,
so they require no Codex login, model usage or desktop permission. They cover
UI projections, creation/manifests, HTTP submission, serialization, failures,
retry/dismiss, event pagination, restart recovery, schedule/manager persistence,
idle and overdue checks, task execution, memory commits and the local HTTP boundary.
Real Codex and Accessibility checks are separate local smoke tests.

To update a component, check out the desired commit inside its submodule,
run these checks and the browser smoke test, then commit the changed Git link
in `sapiens4`. Runtime data, generated assets and binaries stay out of Git.

### Token usage and execution limits

Open a Sapi's **…** settings for token consumption over the last hour, 24 hours,
and seven days, plus recent calls and editable budget/execution limits. Cached
input, uncached input, and output remain separate. Missing provider usage is
shown as unavailable. The local budget weights cached input at 10%; it is not a
price estimate or a Codex account limit. `GET /api/agents/<id>/usage` returns the
same report. See [usage and watcher recovery](usage-and-watcher-recovery.md)
for accounting, historical-data limitations, and scheduling behavior.

### Script-first watchers

Recurring inbox watchers now check a saved observation plan before calling the model. Unchanged checks consume no model tokens. Each Sapi chooses and tests its own strategy before routine execution. A missing plan gets one bounded setup turn; costly or unproductive runs trigger a bounded review. See [agent-owned strategies](agent-owned-strategies.md) for the lifecycle and current execution limits. Configure chat scope, cooldown and hourly/daily wake limits under **Jobs → Edit**. Explicit generative jobs can opt into interval-based model calls.

The **…** settings are split into **Profile, Schedule, Memory, Usage and Limits**. See [script-first watchers](script-first-watchers.md) for the investigation, configuration, coverage limits and validation.

### Sapi workspace operations

Each Sapi sees its current tab titles/IDs and saved artifact names in
`host-facts.workspace`. Through host-control it can use `workspace`,
`artifact_save`, `artifact_read`, `workspace_open`, and `workspace_close`.
`artifact_save` accepts text or a relative UTF-8 source file in that Sapi's
workspace. It saves `.md`, `.html`, `.txt`, or `.json` under `artifacts/` and
opens its tab by default. Saving the same name updates the document/dashboard.
HTML dashboards run in an isolated frame with inline scripts and no network
access. Plain-text artifact URLs never execute generated HTML in the host origin.

Tabs synchronize live with the UI. Workspace revisions reject stale browser
writes; reconciliation keeps independent browser edits and host-created tabs.
A failed or interrupted run remains available for review, but does not prevent
new chat. Sending a follow-up does not retry the failed run. Tool-limit stops
retain the last observation and identify artifacts saved during that attempt.

Focused checks: `PYTHONPATH=tests python3 -m unittest test_workspace -v` and
`node tests/workspace_merge.test.cjs`.

Artifacts have permanent mention tags: `@art-md0016:proposal` for Markdown,
`@art-html0017:dashboard` for HTML (also `txt` and `json`). The four digits are
allocated randomly without tag collisions. Updates keep the tag; previous title
handles remain aliases. Existing files are indexed without changing their contents.
Artifact mentions and recognized old file links open the owner's workspace tab.
External HTTP(S) chat links open a separate browser tab with a compact label.

### Bounded computer reads and partial results

Blindly stays unchanged. `sapiens/computer.py read --pid PID --path PATH --depth 12`
reads one bounded AX tree, selects the discovered container, and returns compact
rows with original paths. Follow `next_offset` using `read --snapshot ID --offset N`;
these pages reuse the same observation for 90 seconds. This is bounded coverage,
not proof that the newest or every message was read. `find` results are compacted
before applying the output limit.

When a tool limit interrupts a run that saved an artifact, the host returns a
**Warning** with the artifact reference and incomplete-coverage notice, without
another model call or automatic retry. The SDK records a terminal run with warning
metadata; CORPORA displays Warning rather than Completed or Failed. Budget usage
remains unknown when the provider did not report it; the existing conservative
charge is retained. Runs without a saved deliverable still report the error.

After computer use, the host attempts to bring the originating browser/Codex app
back to the foreground, including on errors and timeouts. If no browser origin
was captured, it opens the configured local CORPORA URL. Restore failures are
reported as warnings rather than hiding the task result.

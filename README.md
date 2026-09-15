# Sapiens4

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
- **Chat** sends a message through AgentPy's text-only conversation flow.
- **Computer task** runs the execution role with Blindly4 instructions and stores
  the answer in conversation history. For example: “Use Blindly4 to list the open apps.”
- **Jobs** shows queued/running/completed/failed states and token accounting.
- **Log** shows real runtime events and Codex command/tool activity, polled every 750 ms.
- Retry failed, interrupted, conflicting or budget-blocked jobs; dismiss stopped
  jobs or cancel work that is still queued. Running calls finish or hit their deadline.
- Per-Sapi browser tabs, drafts and panel preferences persist in SQLite.

Groups, shared boards, group tasks, roles and recurring schedules are the next
iteration. Their simulated controls are disabled/hidden in this application.
No prototype messages, fake execution timers or sample attachments are used.

### Computer access

Blindly4 needs macOS Accessibility permission for the terminal or application
hosting the server. If needed, run:

```sh
./blindly4/.build/release/blindly4 request-permission
```

Enable the host in **System Settings → Privacy & Security → Accessibility**.
Missing permission is reported as a failed computer job; the app does not grant
permission automatically. The computer card shows build/ownership status, not
a claim that Accessibility permission has been granted.

All jobs are serialized by this server, including jobs from different Sapis.
Only one unresolved job per Sapi is accepted. Computer ownership represents
this server's execution queue; it does not lock out other desktop applications
or independently launched agent processes. The inherited Codex execution
backend runs local tools without sandboxing. Blindly4 guidance preserves its
PID, fresh AX path and exact-draft checks. Ordinary chat uses the SDK's
text-only prompt; this distinction is behavioral, not an OS sandbox.

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
| `corpora.sqlite3` | UI profiles, projected messages/job results/events, browser tabs, drafts and panel preferences; schema version 1, SQLite WAL |
| `agentpy/agents/<id>/` | AgentPy's existing atomic JSON state, manifests, budgets and run locks |
| `agentpy/corpora/` | AgentPy's shared artifacts, directory, mailboxes, receipts and archives |
| `workspaces/<id>/` | Working directory for that Sapi's Codex calls and generated files |
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
| PUT | `/api/agents/<id>` | Update `{name, role}` while idle |
| POST | `/api/agents/<id>/messages` | Submit `{text, flow: "chat" or "computer"}` |
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
retry/dismiss, event pagination, restart recovery and the local HTTP boundary.
Real Codex and Accessibility checks are separate local smoke tests.

To update a component, check out the desired commit inside its submodule,
run these checks and the browser smoke test, then commit the changed Git link
in `sapiens4`. Runtime data, generated assets and binaries stay out of Git.

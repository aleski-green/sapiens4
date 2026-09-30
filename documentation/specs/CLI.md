# Sapiens4 terminal client

Status: working first version on `sapiens4-cli`. Uses the running CORPORA host and its existing data. No separate database, simulated content or browser UI.

## Start

From the checkout:

```sh
./sapiens4
```

A terminal opens an interactive prompt with a short About section and aggregate live stats: host/provider, active/retired Sapi counts, running/queued/waiting work and upcoming/past task counts. Startup does not list Sapis, task bodies or conversations; request those through commands. With redirected stdin, no arguments prints status once. Use `./sapiens4 shell` to explicitly select the prompt. Python 3.9+ and a running CORPORA host are required; no new packages or build step.

The client discovers the port from the managed app's configuration, falling back to 4174. Override with `SAPIENS4_URL` or `--url http://127.0.0.1:PORT`. Requests remain loopback-only, bypass proxies, reject redirects and preserve the API's local JSON headers.

Inside the prompt, omit the executable prefix:

```text
use Refactor
history --limit 1
tasks
memo show
use chief
chat "Prepare a release checklist" --wait
exit
```

`use` accepts an exact ID or unique exact name. Chief is resolved from the host's authoritative `main_agent_id`. Arrow keys recall non-chat commands within the session; history is not saved to disk. The prompt refreshes data when a command executes; `status --watch` polls continuously until interrupted or its deadline.

## Commands

| Command | Behavior |
| --- | --- |
| `status [--watch]` | Host status, active/retired Sapi counts, queued/running conversations, and pending clarification. |
| `doctor` | Host health, readable state, provider identity and reported computer build. Provider authentication is explicitly **not checked**: the current API has no probe. |
| `sapi list [--all]` | Active identities and observed status; `--all` includes retired Sapis. |
| `sapi show <id-or-name>` | Identity, role, workspace and orchestration details. |
| `task list [--tab upcoming\|past\|all]` | Existing task metadata. Defaults to all; groups states exactly like CORPORA. |
| `task show <id>` | Existing YAML body, result and error. |
| `history [--limit 5]` | Recent inputs, replies, states and IDs for the selected Sapi. |
| `memo show` | Current Notes converted from HTML to readable terminal text. JSON retains the source. No memory migration. |
| `chat "message" [--wait]` | Submit once to Chief or the selected Sapi. Return an accepted turn ID, optionally observe to completion. |
| `chat "answer" --workload <id> --sapi chief` | Bind clarification to the waiting Chief workload. |
| `conversation watch <id>` | Observe an existing turn; follows the tracked workload's latest delegated call. |
| `conversation retry <id>` | Explicit retry through existing eligibility checks. |
| `conversation cancel <id>` | Existing API cancellation behavior only, subject to backend eligibility. |

Shared options: `--sapi chief|<id-or-name>`, `--format human|json|jsonl|yaml`, `--plain`, `--no-animation`, `--url`, `--timeout 120`. `task list/show --sapi all` deduplicates tasks across active Sapis. Select a retired Sapi explicitly to inspect its history. `sapis` and `tasks` are aliases; `use`, `exit` and `quit` are prompt-only commands.

Only Chief creates Sapis. There is no `sapi create` command; ask Chief in chat. Jobs, Groups, WorkGraphs, WorkFlows, SapiHarness and AgencyRun remain future runtime capabilities, not aliases for today's conversations. Lifecycle start/update commands from the original proposal are deferred; open the existing app or use `./start.sh` for now.

## Output and observation

Human output uses each Sapi's saved CORPORA face, wrapped in parentheses exactly as in the app. Identity stays the same across ready, queued, running, waiting, completed and failed states; status is a separate text label. Lists, task owners, conversations, Memo and the selected prompt use that Sapi's avatar. Delegated observations use the current owner's avatar. Host status and errors have no invented faces; missing avatars are omitted. Terminal control sequences in backend text are removed. `--plain` uses ASCII text only. Output wraps to terminal width.

Waiting indicators appear only on an interactive human stderr stream and use punctuation animation. They display observation elapsed time, not a fabricated progress percentage. `--plain`, `--no-animation`, `NO_COLOR` and non-TTY stderr suppress animation. Noninteractive human watches print changes, without cursor controls.

JSON emits exactly one versioned response on stdout, including parser/host errors. For `chat --wait`, the response contains the final observation. JSONL is limited to watches and emits an initial snapshot, observed changes and a timeout/detach/error event; it is not a replayable server event log. YAML is limited to `task show` and emits the task body only; use human/JSON to include the result.

```json
{"schema_version":1,"ok":true,"data":{"id":"turn-id","state":"Completed","output":"Result"},"error":null}
```

Errors have `code`, `message` and `hint`; an observation error may include the last data as stale context. Exit codes: 0 successful command or observed completion; 1 failed operation; 2 usage/not found; 3 host unavailable; 4 observation timeout; 5 Admin input required; 130 detached. Submission success means accepted, not completed. The prompt stays open after command failures.

Watches poll every second, with bounded requests and a finite observation deadline (default 120 seconds). Current implementation exits on connection loss and marks the last observation stale; it does not reconnect automatically. Ctrl-C detaches observation without cancelling the server's work. Waiting for Admin stops animation and provides a workload-bound reply command. Never automatically retry a submission with an uncertain response.

## Structure and validation

`./sapiens4` is a small entrypoint. The launcher and three CLI modules total 400 physical lines, including blank lines. A cached command/option registry drives parsing, validation and help; shell and one-shot commands share dispatch and error handling. Three host-side leaves own the CLI: `cli.py` for parsing/prompt/command orchestration, `cli_transport.py` for loopback transport, and `cli_render.py` for text, envelopes and waiting indicators. They do not import execution or database implementations. The existing agent-facing `host/client.py` protocol is unchanged.

Tests use a separate loopback fixture to verify output/error contracts, task selection, clarification payloads, one-shot writes, ambiguous response handling, bounded watches, interruption and the interactive entrypoint. Read-only smoke checks exercise current CORPORA content. No live chat is submitted as part of verification.

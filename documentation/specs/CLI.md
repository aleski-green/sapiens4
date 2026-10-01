# Sapiens4 terminal client

Status: working first version on `sapiens4-cli`. Uses the running CORPORA host and its existing data. No separate database, simulated content or browser UI.

## Start

From the checkout:

```sh
python3 -m pip install --user -r requirements-cli.txt
./sapiens4
```

A terminal opens an interactive prompt with a short About section and aggregate live stats: host/provider, active/retired Sapi counts, running/queued/waiting work and upcoming/past task counts. Startup does not list Sapis, task bodies or conversations; request those through commands. With redirected stdin, no arguments prints status once. Use `./sapiens4 shell` to explicitly select the prompt. Python 3.9+ and a running CORPORA host are required. Interactive input uses `prompt_toolkit` from `requirements-cli.txt` to handle colored prompts, wrapping, completion and history together; no build step is required. One-shot commands and redirected shell input do not require that package.

The client discovers the port from the managed app's configuration, falling back to 4174. Override with `SAPIENS4_URL` or `--url http://127.0.0.1:PORT`. Requests remain loopback-only, bypass proxies, reject redirects and preserve the API's local JSON headers.

The shell starts in `corpora`, with no Sapi selected:

```text
>> sapiens4 ⌘ corpora > show
corpora
├── *(◕ᵕ◕) PINK-SapiTheChief · Head of Corpora
└── (^‿^) Refactor · Code quality and architecture reviewer

>> sapiens4 ⌘ corpora > show @Refactor
>> sapiens4 ⌘ corpora > call @Refactor
(^‿^) Refactor · Code quality and architecture reviewer
id: sapi_26220193ca50
workspace: /path/to/sapiens4/.sapiens4/workspaces/sapi_26220193ca50
Status: ready

sapiens4 ⌘ @Refactor > Review the CLI architecture.
sapiens4 ⌘ @Refactor > chat -5
sapiens4 ⌘ @Refactor > corpora
>> sapiens4 ⌘ corpora > chat @Refactor -5
>> sapiens4 ⌘ corpora > exit
```

This abbreviated example illustrates navigation; `show` uses all active Sapis from the live host. Chief appears first with `*` before its saved face; each dot introduces the saved title. The organization is flat, with all current Sapis under `corpora`. `show --all` also includes retired Sapis. `show @name` inspects without changing context; `call @name` enters a conversation and displays title, ID, actual workspace path and status. Missing workspace information is reported as unavailable. Quote names containing spaces, for example `call @"Code Reviewer"`. IDs and exact unique names are accepted; `@chief` resolves the host's authoritative `main_agent_id`.

Inside a Sapi, plain text sends one message and observes its response. Quotes and option-like text are preserved. The reserved commands are `chat`, `help`, `corpora`, `exit` and `quit`; other text is a message. `chat` defaults to the last five individual messages; `chat -N` selects a positive count, ordered by turn creation with each input followed by its available reply/error. Pending replies are omitted. In corpora, use `chat @name [-N]` to read history without entering that Sapi. Reads never submit a message. `corpora` returns without cancelling work; during an active observation, use Ctrl-C first to detach.

Existing one-shot commands remain available from the OS terminal and from the corpora context. `./sapiens4 chat "message" --sapi name --wait` still submits; in a selected Sapi's prompt, use plain text instead. Workload-bound clarification commands shown by the observer should be run from the corpora context (return with `corpora` first). Tab completes active Sapi names after `@` in `call`, `show` and `chat`; type a prefix to narrow matches, then press Tab again to list ambiguous choices. Names containing spaces are quoted automatically. Completion reads the current host roster. The terminal editor handles keys consistently on macOS and GNU/Linux. Up/Down browse the last 100 inputs in the current context, including messages; corpora and each Sapi have separate histories. Down returns to the current draft after the newest entry. Consecutive duplicates are omitted. History stays in memory for the session and is cleared on exit; no history file is written. The prompt refreshes data when a command executes; `status --watch` polls continuously until interrupted or its deadline.

## Commands

| Command | Behavior |
| --- | --- |
| `status [--watch]` | Host status, active/retired Sapi counts, queued/running conversations, and pending clarification. |
| `doctor` | Host health, readable state, provider identity and reported computer build. Provider authentication is explicitly **not checked**: the current API has no probe. |
| `show [--all]` | Sapi tree with saved titles and Chief marker; `--all` includes retired Sapis. |
| `show @name` | Identity, title, ID, workspace and status, without changing context. JSON retains orchestration details. |
| `call @name` (shell) | Enter the named Sapi; subsequent text sends messages. |
| `corpora` (shell) | Return to the organization prompt. |
| `chat @name [-5]` / `chat [-5]` (shell) | Read individual messages; omit the name inside a Sapi. |
| `messages --sapi name [--limit 5]` | One-shot equivalent of shell chat history, including JSON output. |
| `task list [--tab upcoming\|past\|all]` | Existing task metadata. Defaults to all; groups states exactly like CORPORA. |
| `task show <id>` | Existing YAML body, result and error. |
| `history [--limit 5]` | Recent inputs, replies, states and IDs for the selected Sapi. |
| `memo show` | Current Notes converted from HTML to readable terminal text. JSON retains the source. No memory migration. |
| `chat "message" [--wait]` | Submit once to Chief or the selected Sapi. Return an accepted turn ID, optionally observe to completion. |
| `chat "answer" --workload <id> --sapi chief` | Bind clarification to the waiting Chief workload. |
| `conversation watch <id>` | Observe an existing turn; follows the tracked workload's latest delegated call. |
| `conversation retry <id>` | Explicit retry through existing eligibility checks. |
| `conversation cancel <id>` | Existing API cancellation behavior only, subject to backend eligibility. |

Shared options: `--sapi chief|<id-or-name>`, `--format human|json|jsonl|yaml`, `--plain`, `--no-animation`, `--url`, `--timeout 120`. `task list/show --sapi all` deduplicates tasks across active Sapis. Select a retired Sapi explicitly to inspect its history. `sapi list`, `sapi show <name>`, `sapis`, `tasks` and shell `use <name>` remain compatibility aliases. `exit` and `quit` are prompt-only commands.

Only Chief creates Sapis. There is no `sapi create` command; ask Chief in chat. Jobs, Groups, WorkGraphs, WorkFlows, SapiHarness and AgencyRun remain future runtime capabilities, not aliases for today's conversations. Lifecycle start/update commands from the original proposal are deferred; open the existing app or use `./start.sh` for now.

## Output and observation

Human output uses each Sapi's saved CORPORA face, wrapped in parentheses exactly as in the app. Identity stays the same across ready, queued, running, waiting, completed and failed states; status is a separate text label. Lists, task owners, conversations and Memo use that Sapi's avatar. Prompts use the namespace `>> sapiens4 ⌘ corpora >` or `sapiens4 ⌘ @name >`, with `sapiens4` in logo pink (`#ff5aa5`), `corpora` in the website's pastel green (`#d9e9b8`), and the prompt symbols in its dark-palette muted gray (`#b9b0bd`). Sapi names retain the terminal's default text color. Displayed IDs use muted green (`#a7bdb6`). The interactive editor parses prompt colors as styled text and measures only visible characters, so repeated history navigation and wrapped input retain the prompt and palette. Raw color codes are never passed to libedit. Delegated observations use the current owner's avatar. Host status and errors have no invented faces; missing avatars are omitted. In interactive terminals, avatars use the saved CORPORA pastel background with dark lettering. Headings use cyan, ready/completed states green, queued/running/waiting states amber and errors red. These are CLI presentation colors only; CORPORA data and UI are unchanged. Terminal control sequences in backend text are removed before the CLI applies its own colors. `--plain` uses ASCII text only, with `::` as the prompt separator. Output wraps to terminal width. Colors are disabled for redirected output, machine formats, `--plain`, `TERM=dumb` and any defined `NO_COLOR` environment variable.

Waiting indicators appear only on an interactive human stderr stream and use punctuation animation. They display observation elapsed time, not a fabricated progress percentage. `--plain`, `--no-animation`, `NO_COLOR` and non-TTY stderr suppress animation. Noninteractive human watches print changes, without cursor controls.

JSON emits exactly one versioned response on stdout, including parser/host errors. For `chat --wait`, the response contains the final observation. JSONL is limited to watches and emits an initial snapshot, observed changes and a timeout/detach/error event; it is not a replayable server event log. YAML is limited to `task show` and emits the task body only; use human/JSON to include the result.

```json
{"schema_version":1,"ok":true,"data":{"id":"turn-id","state":"Completed","output":"Result"},"error":null}
```

Errors have `code`, `message` and `hint`; an observation error may include the last data as stale context. Exit codes: 0 successful command or observed completion; 1 failed operation; 2 usage/not found; 3 host unavailable; 4 observation timeout; 5 Admin input required; 130 detached. Submission success means accepted, not completed. The prompt stays open after command failures.

Watches poll every second, with bounded requests and a finite observation deadline (default 120 seconds). Current implementation exits on connection loss and marks the last observation stale; it does not reconnect automatically. Ctrl-C detaches observation without cancelling the server's work. Waiting for Admin stops animation and provides a workload-bound reply command. Never automatically retry a submission with an uncertain response.

## Structure and validation

`./sapiens4` is a small entrypoint. The launcher and three CLI modules total 400 physical lines, including blank lines. A cached command/option registry drives parsing, validation and help; shell and one-shot commands share dispatch and error handling. Three host-side leaves own the CLI: `cli.py` for parsing/prompt/command orchestration, `cli_transport.py` for loopback transport, and `cli_render.py` for terminal input, text, envelopes and waiting indicators. They do not import execution or database implementations. The existing agent-facing `host/client.py` protocol is unchanged.

Tests use a separate loopback fixture to verify output/error contracts, task selection, clarification payloads, one-shot writes, ambiguous response handling, bounded watches, interruption the interactive entrypoint, corpora/Sapi navigation, exact message submission, individual-message history, prompt colors, and actual terminal Up/Down keys, draft restoration and context history. A VT terminal emulator verifies visible prompt text and palette after repeated Up/Down navigation and wrapping in a 50-column terminal; this catches redraw failures that command-result checks alone cannot detect. Read-only smoke checks exercise current CORPORA content. No live chat is submitted as part of verification.

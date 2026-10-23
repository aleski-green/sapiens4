# Behavior contracts with RSpec

RSpec is the repository's test entrypoint. The Python application runs as a
separate process; no test imports its modules or monkey-patches its classes.
RSpec examples own the behavioral specifications. Python remains the runtime
under test, and the requirements file installs its runtime dependencies only.

## Run

Use Ruby 3.4, Python 3.11 or newer, and Node.js 20 or newer. Initialize the
Blindly4 submodule before running desktop/updater cases.

```sh
git submodule update --init --recursive
bundle install
python3 -m pip install -r spec/requirements.txt
npm ci --prefix tests --ignore-scripts
SAPIENS_PYTHON=python3 bundle exec rspec
```

Set `SAPIENS_PYTHON` to an absolute virtual-environment interpreter when needed.
Tests never use a real Codex login: a temporary executable implements the model
CLI protocol. Every service example has its own data directory, including spaces,
an apostrophe and Unicode, and a random loopback port. Failed assertions still
shut down owned processes. Timeouts terminate their remaining descendants.

```sh
bundle exec rspec spec/workflow_spec.rb
bundle exec rspec --tag '~slow'       # quick iteration; not the complete check
bundle exec rspec --seed 12345        # reproduce an ordering failure
```

The full suite includes real minute-based scheduling. There is no accelerated
clock or test-only endpoint in production. Persisted installation fixtures cover
overdue schedules and the 1,000-run boundary without waiting for 1,000 minutes.
SQLite is used only to prepare offline installation inputs; behavior is asserted
through the running service. No runtime database access is used as an assertion
shortcut.

On Windows, install .NET 10 and build the external provider launcher before
running the suite:

```powershell
dotnet build spec/support/windows/CodexFixture.csproj -o tmp/codex-fixture
$env:SAPIENS_TEST_CODEX = (Resolve-Path tmp/codex-fixture/CodexFixture.exe).Path
$env:SAPIENS_PYTHON = 'python'
bundle exec rspec --tag '~windows'
```

For the packaged desktop contract, first run `windows/build.ps1`, set
`SAPIENS_TEST_WINDOWS_PACKAGE` to the resulting package directory, and run the
full suite. The Windows CI matrix performs this for x64 and ARM64. The launcher
inherits standard streams and starts Ruby as a child so the real Windows Job
Object still owns and cancels the provider process tree.

## Migration map

The former 24 Python files contained 274 test methods. They are replaced by
observable scenarios, not translated method for method. Independent invalid
inputs remain separately named examples; a lifecycle or recovery scenario may
cover several former methods.

| Former Python coverage | RSpec replacement |
| --- | --- |
| Integration, chat controls, lifecycle, model defaults, team creation | `service_spec.rb`: real HTTP, persistence, retry, attachments, authorization, legacy installation recovery |
| Parallel execution, pulsation, Codex processes, Windows host primitives | `service_spec.rb`: bounded concurrency, batching, output order, process crash, exclusive computer leases, Unicode stdin and descendant cancellation |
| Delegation and completion | `workflow_spec.rb`: routing, specialist creation, clarification, cancellation, recipient recovery, audited prompts, conditional completion evidence |
| Groups | `groups_spec.rb`: routing isolation, roles, membership limits, task revisions, late results, archive/restore, attachments |
| Notes, workspace, text previews | `workspace_spec.rb`: scoped files, unsafe URLs, stale navigation, persistent tabs, memo context and migration |
| Routines and lifecycle events | `scheduling_spec.rb`: real scheduling, overdue admission, pause/resume, run limit, ownership, event attribution and no duplicate polling events |
| CLI | `cli_spec.rb`: real processes and a POSIX terminal against a controlled HTTP peer; output, clarification, draft/history navigation, completion, observer detachment, errors and no write retries |
| Remote pairing, encryption, relay and setup | `remote_spec.rb`: real host and relay, independent NaCl peer, WebSocket replay/ack, approval failure and expiry, saved QR/setup, discovery lifecycle, allowlists, tampering, revocation and private-state boundaries |
| Preflight | `preflight_spec.rb`: external executable discovery, version/login/model failures and isolated read-only model probe |
| Runtime distribution | `distribution_spec.rb`: source-only release boot, actual provider call, generated frontend syntax; updater cases also exercise legacy public entrypoints |
| Desktop updater | `updater_spec.rb`: real CLI against temporary releases, mocked external build tools, activation barrier, waiting for work, unrelated-app refusal, cache cleanup, preparation failure, backups, commit/rollback journals and atomic bundle recovery |
| Native/browser integration and computer presentation | `platform_spec.rb`: existing DOM and native platform probes, real WebKit connected to the HTTP service, packaged Windows checks |

## Deliberately changed coverage

Import-graph, folder-count, private helper, mocked method-call-count and exact
internal object-layout assertions were retired. Those checks constrained a
particular implementation rather than demonstrating a service contract.

Process crash and persisted-journal scenarios cover recovery outcomes. They do
not force every instruction-level crash window previously injected by patching
`_sync`, nor do they prove all arbitrary crash interleavings. Exact remaining
timeout arguments between decision nodes and arbitrary synthetic pulse-clock
jitter are also no longer inspected. The suite does not wait thirty minutes to
exhaust the model deadline. These are explicit limits, not claims of identical
line or branch coverage.

The real terminal case verifies navigation, draft restoration and intentional
submission. Exact per-cell colors and cursor layout on a narrow terminal are
not asserted by this migration.

Existing JavaScript and Swift/C# harnesses remain platform probes called from
RSpec. Some legacy probes still contain their original assertions. New behavior
cases and assertions belong in RSpec; runtime-specific helpers should expose
actions and observations. Blindly4 is an external Rust submodule with its own permission-free RSpec
contracts. Build it with `./blindly4/macos/build.sh`, then run its suite from
`blindly4/` with `BLINDLY4_BIN=.build/release/blindly4 bundle exec rspec`.

Adding a fake Python service or a general Ruby-to-Python RPC bridge would defeat
the boundary. Extend the controlled external provider or HTTP peer only when a
new observable scenario needs it. Use fresh environments, bounded condition
polling, and explicit expected effects; do not replace several assertions with
only a process exit-code check when the service exposes the actual result.

The retired standalone phone and desktop pairing pages are now covered through
`install_spec.rb`, `corpora_browser_spec.rb`, `remote_browser_spec.rb` and
`app_remote_spec.rb`, using the shipped workspace, QR scanner and encrypted
transport. These retain QR validation/capture, camera cancellation, import safety,
matching-code approval, binary responses, identity binding, trust migration,
revocation and tab handoff checks. The old ID-entry wizard and carousel no longer
exist. The current transport rejects interrupted requests instead of automatically
replaying writes; the regression contract checks that no write is replayed.
Browser probes simulate mobile installation state and Android's install event;
physical Android installation and keyboard behavior still require a device run.

### Native workspace accessibility

On a macOS desktop with Accessibility permission for the invoking terminal, run
`SAPIENS_TEST_BLINDLY4=/absolute/path/to/blindly4 bundle exec rspec spec/workspace_accessibility_spec.rb`.
This opt-in contract uses the real WebKit workspace against an isolated host and
local player fixtures. It checks AX discovery and pressing, selected-tab isolation,
focus after closing/hiding a guest, window resizing and the shell's update-banner
inset. It never opens the user's installation or an external video service.
Without the environment variable these desktop-input cases are pending; the
regular WebKit navigation/isolation probe still runs in `platform_spec.rb`.

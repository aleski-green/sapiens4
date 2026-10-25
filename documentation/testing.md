# Behavior contracts with RSpec

RSpec owns all scenarios and assertions. Tests drive the running application via
public HTTP, the encrypted relay protocol, or native accessibility through
Blindly4. They do not import application modules, call UI functions, evaluate
JavaScript, inspect DOM nodes/CSS, or replace browser APIs. There are no JavaScript
test files or JavaScript snippets hidden in native probes. Production browser
adapters run compiled PureScript/Halogen and the shared foreign bindings.

## Run

Use Ruby 3.4, Python 3.11+, Node.js 22.5+ and npm. Initialize the pinned submodules:

```sh
git submodule update --init --recursive
ruby libs4/ruby/bundle.rb install
python3 -m venv libs4/python/.venv
libs4/python/.venv/bin/python -m pip install -r libs4/python/remote-requirements.txt
python3 web/shell/build.py
ruby libs4/ruby/bundle.rb exec rspec
```

The wrapper keeps gems and the Python environment in libs4. Set `SAPIENS_PYTHON`
to override the interpreter. Node and npm build the UI and validate clean source releases.
Every service scenario uses temporary data, a loopback port and a controlled
external model executable; tests never use a real model login or existing corpora.

Run desktop behavior scenarios on an unlocked desktop with Accessibility access:

```sh
./blindly4/macos/build.sh
SAPIENS_TEST_BLINDLY4="$PWD/blindly4/.build/release/blindly4" ruby libs4/ruby/bundle.rb exec rspec --tag desktop
SAPIENS_TEST_BLINDLY4="$PWD/blindly4/.build/release/blindly4" ruby libs4/ruby/bundle.rb exec rspec
```

These scenarios bring an isolated fixture window forward and use real mouse,
keyboard and accessibility actions. Run them serially and avoid interacting with
the fixture during a run. Missing platform/desktop configuration is reported as
pending. Once configured, permission errors and failed interactions are failures.
`tmp/desktop-failure.txt` records accessible window content for a failed scenario.

The macOS fixture loads the shipped workspace with the production Browser adapter
in WebKit. It adds only a native reload command and window resizing; it exposes no
application test bridge. Each process has a private browser profile. On Windows,
the fixture runs the production MainWindow and WebView2. Element paths come from
the current accessibility tree, never hard-coded DOM or native tree indexes.

For Windows, install .NET 10 and build the external model launcher:

```powershell
dotnet build spec/support/windows/CodexFixture.csproj -o tmp/codex-fixture
$env:SAPIENS_TEST_CODEX = (Resolve-Path tmp/codex-fixture/CodexFixture.exe).Path
$env:SAPIENS_TEST_BLINDLY4 = 'C:\path\to\blindly4.exe'
$env:SAPIENS_PYTHON = 'python'
ruby libs4/ruby/bundle.rb exec rspec
```

Build the application using `windows/build.ps1` and set
`SAPIENS_TEST_WINDOWS_PACKAGE` to validate its shipped runtime as well. Run x64 and
ARM64 packages on matching systems. The package contract drives the actual window;
it does not invoke the retired script-injection smoke-test mode. The remote-browser
and HTTP-proxy window scenarios currently require macOS and are explicitly
pending on Windows; the other desktop scenarios share the native driver.

## Boundaries and coverage

| Behavior | Scenarios |
| --- | --- |
| Sending messages, saved task history, Memo, late task/Memo replies, retry, drafts during send confirmation, search, per-person workspace | `ui_state_spec.rb`, through Blindly4 and the real service |
| Incoming replies while composing or reading older messages | `chat_scroll_spec.rb`, using native input and accessible on-screen positions |
| Shared group messages, personal-chat isolation and Group-only task filters | `groups_browser_spec.rb` |
| Creating/switching corpora, pause/resume, preserving drafts and execution state | `corpora_browser_spec.rb` |
| Relay JSON validation, save, cancel/confirm switching | `relay_browser_spec.rb` |
| Matching-code approval, remote message delivery, saved draft and reconnection, invalid invitations | `app_remote_spec.rb`, shipped remote app with real host and relay |
| Native tabs, unframeable websites, links, bookmarks, text files, reload, menus, resize | `workspace_accessibility_spec.rb` |
| Installation URLs, manifests, icons, old-link redirects and private-route rejection | `install_spec.rb`, `remote_spec.rb` |
| Lifecycle, delegation, shared groups, files, scheduling and recovery | Service RSpec files, against public HTTP and external model inputs/outputs |
| Authentication, tampering, replay, revocation, mailbox delivery and persisted trust | `remote_spec.rb`, `relay_servers_spec.rb`, independent NaCl/WebSocket peer |
| Source releases, signed macOS builds, selected data retention, packaged Windows runtime | `distribution_spec.rb`, `windows_package_spec.rb` |

`support/remote_peer.py` implements only the public NaCl/WebSocket wire protocol
using runtime dependencies already in libs4. It imports no Sapiens4 code. Ruby
owns the assertions. It does not stand in for browser persistence: that behavior
is exercised through the shipped remote app.

`support/proxy.rb` forwards requests to the real host. A scenario may hold a task
response or return one failed/malformed response at this network boundary. It
never manufactures a workspace snapshot or replaces a UI function. This permits
repeatable request-lifecycle tests while the actual application renders and
handles user actions.

Offline installation files and SQLite fixtures are permitted as startup inputs,
not as live assertion shortcuts. Security tests may contain literal markup or
rejected URL strings as data; they never execute that text as test JavaScript.

The suite retains real minute-based scheduling, source-release startup and signed
build checks. There is no accelerated application clock or test-only service API.
Use `--tag '~slow'` for iteration, not as a substitute for the complete run.

## Device validation still required

The removed DOM simulations did not run iOS, Android, camera hardware, service
workers in an installed app, or operating-system app switching. Desktop results
must not be presented as coverage of these behaviors. Check them on real devices:

- Install from Safari/Chrome, follow the platform's installation instructions and
  verify that the browser gate does not reveal saved connections before install.
- Pair by camera and uploaded QR image; cancel scanning and check the camera turns
  off. Reject invalid/oversized images and retry a valid invitation.
- Background and reopen an iOS app while reading older messages, including near
  the bottom. Keep the same message visible and preserve an unsent draft; respect
  a subsequent manual scroll while reconnecting.
- Reopen cached remote history offline, verify writes are unavailable, reconnect
  and confirm that unsent work was not replayed.
- Update an installed shell, including an interrupted download. Reload through
  the logo online/offline and retain the draft and approved connection.
- Check portrait/landscape pane limits, keyboard resizing, touch scrolling, theme
  contrast and native PDF presentation visually.

Legacy checks of DOM object identity, mutation counts, CSS properties, listener
registration, internal state objects and exact helper results were removed rather
than translated into another language. A passing test should explain a capability
or failure a person or external client can observe, not a chosen implementation.

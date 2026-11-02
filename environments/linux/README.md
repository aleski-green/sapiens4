# Ubuntu adapter

Targets: Ubuntu 22.04 and 24.04 LTS, amd64, on native GNOME desktops and WSL2,
with both headless and desktop execution. **Development preview; enterprise
production qualification is incomplete.** The macOS adapter remains separate.
The [compatibility audit](AUDIT.md) records the repaired desktop command routing
and remaining workflow coverage gaps; full application compatibility is not established.
Linux selects an explicit backend: an owned Playwright browser for headless use,
or the native GTK/WebKit desktop with Blindly4. Desktop sessions inside WSL2 need
a working GNOME session; WSLg alone is not GNOME and cannot host its verifier.

## Run from source

Use GHC 9.14.1, Cabal 3.18.2, Node 24.22.2 and the pinned libs4 dependencies.
Ruby 3.4.11 / Bundler 4.0.21 are needed for tests. Browser packages are pinned by
Playwright 1.64.1; do not substitute an independently installed browser version.

```sh
npm ci --prefix submodules/libs4
PLAYWRIGHT_BROWSERS_PATH="$PWD/submodules/libs4/.cache/playwright" \
  node submodules/libs4/node_modules/playwright/cli.js install chromium firefox
runghc build/Build.hs
./environments/linux/start.sh
```

The host prints its local workspace URL. Model calls require a separately
authenticated model CLI. Tests use local fixtures without paid calls.
`build/start.sh` also selects the Linux launcher after building.

For browser runtime libraries and the optional virtual desktop on Ubuntu:

```sh
sudo apt-get install -y libgtk-3-0 libnss3 libnspr4 libasound2 libgbm1 libdbus-glib-1-2 libx11-xcb1 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxkbcommon0 libxcursor1 fonts-liberation fonts-dejavu-core xvfb xauth dbus-x11 openbox x11-utils
```

On Ubuntu 24.04, use `libgtk-3-0t64` and `libasound2t64` instead of their non-t64
names. The package declares both alternatives. Compilation additionally requires
the standard C toolchain, GMP, libffi, NUMA and zlib development headers.

The data directory is `$XDG_DATA_HOME/sapiens4` when XDG is absolute, otherwise
`$HOME/.local/share/sapiens4`. `SAPIENS_DATA_DIR` overrides that default and an
explicit `--data-dir` takes precedence. Browser profiles are temporary and close
with the host; authentication cookies are not persisted between host sessions.

## Execution boundary

`Browser.cjs` translates discovery, navigation, focus, editing, single-select options, scrolling and
guarded press/key operations. `Bridge.cjs` owns the browser, bounded command queue
and private Unix socket. The host launcher starts and stops that session.
The core computer wrapper retains its existing host ownership check before
dispatch. No native macOS implementation is imported or invoked on this path.

Launch `Browser`/`Chromium`/`Chrome` or `Firefox`, then navigate using
`blindly open --url https://…`. `headless.sh schema` publishes supported syntax.
Here, `Chrome` names the pinned Chromium engine, not a user's Chrome installation.
The returned PID identifies the owned session; it does not prove OS foreground
ownership. Observations have bounded output, explicit coverage and pagination.
Retained element references expire after 90 seconds and fail after navigation.
Password values are redacted and password editing is refused. Guarded submissions
require an exact draft match. Commands are serialized and mutations are not retried.
Disconnecting during a command closes the browser before queued work proceeds.
Launch again to recover; old paths and snapshots are invalidated, and completed effects are not undone.
No arbitrary JavaScript execution command is exposed.

The socket directory is user-owned mode 0700 and its socket mode 0600. Browser
sandboxing remains enabled. This protects against other OS users, not malicious
processes running under the same account. Keep the host's existing authentication
boundary; do not expose its local API by changing network bindings.

For a software-rendered virtual X11 desktop:

```sh
./environments/linux/virtual.sh COMMAND ARGUMENTS...
```

This starts private Xvfb, D-Bus and Openbox sessions, disables X11 TCP listening,
and cleans them up afterward. Headless browser automation does not need Xvfb.
No physical GPU/display, systemd, GNOME, WSL1, custom kernel or manual network
bridge is required. No WSL or Windows network configuration is changed.

## Qualification

All scenarios are RSpec behavioral/integration tests against real hosts, browsers
and virtual displays. On this checkout, `source .build/env.sh` selects the local
toolchains; that ignored file is not part of a release.

```sh
SAPIENS_TEST_HEADLESS_BROWSERS=1 ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_bridge_spec.rb spec/linux_external_browser_spec.rb spec/linux_launch_spec.rb
SAPIENS_TEST_LINUX_VIRTUAL=1 ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_launch_spec.rb --example 'Linux virtual execution'
SAPIENS_TEST_HEADLESS_BROWSERS=1 SAPIENS_TEST_HEADED=1 environments/linux/virtual.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_external_browser_spec.rb
ruby submodules/libs4/ruby/bundle.rb exec rspec
```

| Capability | Implementation | Evidence / remaining qualification |
| --- | --- | --- |
| Linux host routing, session lifecycle, private IPC, data paths | Implemented | Ubuntu 24.04 launcher contracts pass |
| Chromium and Firefox command translation | Implemented | 25 headless bridge, launcher and browser examples pass on each Ubuntu release, including Unicode, draft guards, pagination and process isolation |
| Sapiens workspace browser interaction | Implemented | Chromium and Firefox pass Unicode send/reload persistence at 1× and 2×, both headless and Xvfb on 24.04 |
| Ubuntu 22.04 userspace | Implemented and tested | Host build, bridge, launcher, headless browsers and Xvfb browser tests pass in an isolated official Ubuntu userspace on this WSL2 kernel; not a separately enrolled WSL distribution |
| Headless `.deb` | Implemented and tested | Runtime, browser launch and apt install/reinstall/purge pass on 22.04 and 24.04; user data survives removal. Lifecycle tests use disposable images with fakeroot ownership emulation |
| Enterprise network and policy matrix | Pending | Actual Intune-enrolled 22.04/24.04 installations, NAT and mirrored mode, corporate proxy/CA and browser policy checks |

Limitations: one browser and main-frame controls per host session; frames, native
browser chrome, additional tabs/popups, downloads, file dialogs, native app launch
and desktop-wide pointer control are not supported by this bridge. Standard
HTML controls and contenteditable are covered; custom widgets need application
qualification. HTTP(S) navigation can reach whatever the account/network permits.
Exact-draft checking cannot make a changing web application transactionally atomic;
inspect uncertain outcomes before retrying. Browser success is not delivery proof.

Owned headless browsers do not connect to a desktop session bus or autolaunch
desktop services. This prevents Firefox from leaving D-Bus/portal processes behind
when a WSLg display exists without a session bus. Native desktop sessions retain
their real bus for accessibility, foreground verification and consented input.

The [native desktop backend](NATIVE.md) targets GNOME 42/46 on both native Ubuntu
and WSL2. Build with `--desktop`, then launch explicitly:

```sh
SAPIENS_LINUX_BACKEND=desktop ./environments/linux/start.sh
```

`SAPIENS_LINUX_BACKEND=headless` is the default. `native` runs the host with native
computer commands without opening the GTK window. Modes do not silently switch
when permissions or displays are missing. Headless and native installations use
the same data-path rules; do not open the same data directory concurrently.

Full desktop login/lock, hardware, fractional scaling and enterprise portal policy
remain required qualification gates. The isolated GNOME tests here are useful
compatibility evidence, not native-machine or enrolled WSL2 certification.
Older Ubuntu 26.04 experiments do not expand the target list.

## Packaging

Build the host/domain executables in Ubuntu 22.04 so one package can use the
older libc baseline. Package the current UI and adapter sources with those outputs:

```sh
SAPIENS_LINUX_BUILD_DIR=/path/to/ubuntu22-build/.build \
  environments/linux/package-headless.sh .build/packages/sapiens4-headless-ubuntu-amd64.deb
SAPIENS_TEST_HEADLESS_PACKAGE="$PWD/.build/packages/sapiens4-headless-ubuntu-amd64.deb" \
  ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_headless_package_spec.rb
```

The launcher is `sapiens4-headless`, with payload under `/opt/sapiens4-headless`.
There are no installation scripts, autostart entries, kernel/network changes or
GNOME extension installation. An administrator explicitly installs the `.deb`
with apt, which resolves distribution libraries. User corpora are outside the
package. The SHA-256 sidecar detects corruption; it is not a release signature.
The development package requires real ALSA: `libasound2` 1.2.6+ on 22.04 or
`libasound2t64` 1.2.11+ on 24.04. It declares a conflict with
`liboss4-salsa-asound2`; that compatibility provider lacks symbols required by
the bundled browser and cannot substitute for ALSA. Review apt's proposed
replacement when upgrading an installation that previously selected it.
Signing, upgrade/rollback and enrolled enterprise deployment remain release gates.
The current qualification uses real Ubuntu packages and glibc 2.35/2.39, sharing
this machine's stock WSL2 kernel. It does not establish results on a separate
kernel, a physical desktop, or a corporate Intune-enrolled installation.

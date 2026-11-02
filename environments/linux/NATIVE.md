# Ubuntu desktop adapter

Targets: Ubuntu 22.04 / GNOME 42 and Ubuntu 24.04 / GNOME 46, amd64, on native
Ubuntu installations and GNOME desktop sessions inside WSL2. Both desktop and
[headless execution](README.md) are required. This is a development preview;
full desktop and enterprise production qualification is incomplete.
The [compatibility audit](AUDIT.md) records the repaired desktop command routing
and the remaining application and release qualification gaps.

The Linux module embeds the existing host and UI in GTK 3 / WebKitGTK 4.1.
The common GTK 3 baseline avoids GTK 4.6's missing WebKit accessibility integration
on Ubuntu 22.04. macOS native logic remains separate. Desktop computer commands
use Blindly4's Linux adapter: AT-SPI controls, GNOME foreground verification and
consented Wayland input. Xorg retains XRes ownership, EWMH activation and XTest.
Wayland never silently falls back to Xwayland or headless input.

## Build and run

Use the pinned toolchains and libs4 dependencies described in the root README.
Install native SDKs on either Ubuntu release:

```sh
sudo apt-get install -y build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libjson-glib-dev libatspi2.0-dev libx11-dev at-spi2-core dbus-user-session dbus-x11 libglib2.0-bin
runghc build/Build.hs --desktop
submodules/blindly4/linux/build.sh release
SAPIENS_LINUX_BACKEND=desktop ./environments/linux/start.sh
```

Without `--desktop`, the build produces headless targets. The desktop executable
requires a graphical session; `--help` works without one. The model CLI needs
separate installation and authentication. Tests use local model fixtures.
`SAPIENS_DATA_DIR` overrides the normal XDG data directory; an explicit
`--data-dir DIRECTORY` wins. No corpora are migrated.

WSLg alone supplies window transport, not a GNOME Shell session. Headless mode
requires neither GNOME nor a GPU. `environments/linux/virtual.sh COMMAND...`
provides a private software-rendered Xvfb/Openbox session for X11 applications.
The test runner can provide isolated GNOME Wayland or Xorg sessions. These do
not reproduce an actual desktop login, logind, screen lock or device hotplug.
No WSL1, custom kernel, network bridge or Windows networking changes are required.

## Optional foreground verification

Audit `submodules/blindly4/linux/gnome/Foreground.js` and `install.sh` before use.
The installer selects a minimal GNOME 42 legacy loader or GNOME 46/50 module
loader around the same implementation, and advertises only the selected version.
GNOME 50 loader availability does not expand supported distribution targets.

The read-only D-Bus API exposes foreground PID and pointer ownership. It rejects
lock/greeter, overview, Shell modal, hidden and Xwayland windows. It does not
inject input, activate windows, read clipboard contents, capture screens, access
the network or record activity. GNOME extensions nevertheless execute with Shell
privileges; GNOME provides no per-extension permission sandbox.

Neither the application nor its package installs or enables the extension.
An authorized user/admin must explicitly install and separately enable it:

```sh
sh submodules/blindly4/linux/gnome/install.sh --accept-foreground-verification
# Log out and back in before enabling the installed extension.
gnome-extensions enable foreground@blindly4.sapiens4
submodules/blindly4/.build/release/blindly4-input --consent
# Optional pointer access:
submodules/blindly4/.build/release/blindly4-input --consent --pointer
```

Approve the real GNOME remote-interaction dialog. Keyboard-only is the default;
pointer access requires the explicit extra flag. The helper stores no restore
token, never autostarts, and closes its portal session when stopped. Only one
helper should run at a time. Disabling the extension blocks subsequent input.
Disable with `gnome-extensions disable foreground@blindly4.sapiens4`; remove its
user extension directory to uninstall. Packaged paths begin at `/opt/sapiens4/`.
Enterprise policy that forbids extensions prevents guarded Wayland mutation;
the adapter does not bypass policy.

## Implementation and qualification

| Capability | Implementation | Test evidence / remaining work |
| --- | --- | --- |
| Explicit headless/desktop selection | Implemented | Launcher and native lifecycle tests; desktop rejects absent display |
| Embedded browser tabs | Implemented | Real WebKit navigation, reload, history, title/close, host-bridge isolation, owner cookie isolation and restart persistence |
| Native file picker | Implemented | Opening, cancellation and Unicode path selection tested on both Ubuntu releases, Xorg and Wayland; enterprise file policies pending |
| Native downloads | Implemented | Explicit Save/Cancel, existing-file rejection and cancellation on tab closure tested; one transfer at a time, no automatic destination |
| Renderer recovery | Implemented | Guest failure is reported and requires explicit reload; workspace renderer failure stops the host and allows a clean restart |
| AT-SPI discovery and text edits | Implemented | GTK Unicode, password-role redaction, exact-draft rejection and bounded traversal; indexed-child compatibility covers older ATK embedded providers |
| GNOME foreground verifier | Implemented | Actual GNOME 42/46 PID and disable tests; Shell overview rejection tested; real login/lock and other overlays pending |
| Wayland keyboard and pointer | Implemented, explicit portal consent | Software-rendered virtual monitors at actual 1×/2× scale, input and revocation tests; hardware/fractional/layout matrix pending |
| Xorg fallback | Implemented | XRes/XTest native fixtures; GTK/WebKit physical clicks at 1×/2× scale; fractional/mixed monitors pending |
| External Chromium / Firefox | Observation and guarded ASCII keyboard editing implemented | Explicit transport, consent/layout preflight, password rejection, exact submission and ignored-input failure tested. Native Unicode keyboard transfer is unsupported; headless Playwright supports Unicode |
| Desktop `.deb` | Implemented | Ubuntu 22.04 glibc baseline, GTK 3 / WebKitGTK 4.1 dependencies, no installation hooks; qualification results recorded below |
| Native Ubuntu and WSL2 full desktops | Targeted, pending qualification | This machine supplies isolated userspaces/compositors, not physical desktops or enrolled WSL2 fleets |

AT-SPI may acknowledge an edit without performing it. Guarded paste therefore
requires exact draft and focus verification before reporting success; a failed
operation must be inspected before retrying. Chromium does not expose a writable
AT-SPI text interface in the tested build; Firefox acknowledges native writes
without updating the draft. For those applications, explicitly select
`BLINDLY4_LINUX_TEXT_INPUT=keyboard` before launching Sapiens4 or the driver.
There is no automatic fallback or replay after a native write fails.

Keyboard text accepts printable ASCII, at most 4096 bytes. Wayland requires one
GNOME US input source without XKB options, plus portal consent. Xorg reads its
current keymap without modifying it. Unsupported text/layout and absent consent
are rejected before clearing the target. Replacement, insertion and typing
verify the resulting draft; focus and foreground are checked during input.
Password controls remain inaccessible. Unicode still works through editable
AT-SPI controls and owned headless Chromium/Firefox sessions.

The external-browser fixtures launch browsers in headed mode, then exercise
Blindly4 native accessibility and keyboard input. The pinned Playwright builds
and the official Mozilla Firefox 153.6.0esr archive have separate evidence below.
These runs do not qualify distro, Snap or corporate-managed browser builds.

Wayland foreground identity requires the optional extension; the portal alone
cannot provide it. Global element positions are omitted on Wayland. Providers
may reject focus or expose incomplete geometry. Pointer input verifies the
requested destination, waits for compositor motion feedback, then rechecks
ownership before clicking. At most two corrective motions account for observed
input-to-screen scaling; unexpected motion or failure to arrive blocks the click. Clicks and submissions are never retried. Scroll
steps recheck ownership. No screen-capture, clipboard or EIS permission is used.
Editable-text transfer leaves the clipboard untouched. Password protection relies
on correctly declared native roles; applications with incorrect metadata need
separate qualification.

At 100% and 200% Xorg scale, GTK fixture clicks, WebKit viewport zoom and
physical WebKit button clicks pass. Conversion matches accessible window bounds
against XRes-verified geometry, including window decorations. Unknown geometry
is omitted rather than guessed. Document theming remains pending.
Physical displays, GPU paths, fractional/mixed scaling, multiple monitors,
keyboard layouts, actual login/lock, portal revocation policy and enterprise
browser/application matrices remain release gates. Locked dconf policy tests
are local fixtures, not Intune enrollment evidence. NAT/mirrored networking,
corporate proxy/CA, managed browsers and admin installation must be checked on
authorized enterprise installations using the stock Microsoft WSL2 kernel.

## Packaging

Build host, domain, desktop and release Blindly4 binaries against Ubuntu 22.04.
The packager rejects binaries requiring glibc newer than 2.35:

```sh
SAPIENS_LINUX_BUILD_DIR=/path/to/ubuntu22-checkout/.build \
SAPIENS_LINUX_DRIVER_DIR=/path/to/ubuntu22-checkout/submodules/blindly4/.build/release \
  environments/linux/package.sh .build/packages/sapiens4-ubuntu-amd64.deb
```

The package provides `sapiens4` and `/opt/sapiens4`, independently of the headless
package. It includes binaries, UI, prompts, licenses and auditable optional
extension sources. GTK/WebKit remain distribution dependencies. Assembly uses
Cargo metadata and Python 3 to collect locked Rust dependency notices. There
are no credentials, corpora, maintainer hooks, extension installation or autostart
entries. The SHA-256 sidecar detects corruption; it is not a release signature.
Signing and enrolled deployment remain gates. The local lifecycle suite can
exercise development-package upgrade and rollback while preserving user data.

## Reproduce tests

RSpec owns all assertions; native/JavaScript probes only drive external programs.
Install `gnome-shell xdg-desktop-portal-gnome pipewire xvfb x11-utils desktop-file-utils dconf-cli python3-gi`
and GTK 4 development headers for the independent native-control fixture.

```sh
submodules/blindly4/linux/build.sh debug
SAPIENS_TEST_VIRTUAL_DISPLAY=1 SAPIENS_TEST_GNOME_FOREGROUND=1 SAPIENS_TEST_LINUX_AUTOMATION=1 spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_desktop_spec.rb spec/linux_browser_spec.rb spec/linux_foreground_spec.rb spec/linux_automation_spec.rb
SAPIENS_TEST_HEADLESS=1 SAPIENS_TEST_GNOME_FOREGROUND=1 SAPIENS_TEST_LINUX_AUTOMATION=1 spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_automation_spec.rb -e 'clicks and scrolls only' -e 'injects a guarded key'
SAPIENS_TEST_XORG=1 SAPIENS_TEST_GNOME_FOREGROUND=1 SAPIENS_TEST_LINUX_AUTOMATION=1 spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_desktop_spec.rb spec/linux_browser_spec.rb spec/linux_automation_spec.rb
SAPIENS_TEST_VIRTUAL_DISPLAY=1 SAPIENS_TEST_GNOME_FOREGROUND=1 SAPIENS_TEST_LINUX_EXTERNAL_DESKTOP=1 spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_native_browser_spec.rb
SAPIENS_TEST_HEADLESS=1 SAPIENS_TEST_SCALE=2 SAPIENS_TEST_GNOME_FOREGROUND=1 SAPIENS_TEST_LINUX_AUTOMATION=1 spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_automation_spec.rb -e 'requested display scale' -e 'clicks and scrolls only' -e 'injects a guarded key'
SAPIENS_TEST_HEADLESS_BROWSERS=1 ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_bridge_spec.rb spec/linux_external_browser_spec.rb spec/linux_launch_spec.rb
SAPIENS_TEST_CABAL_CACHE="$PWD/submodules/libs4/haskell/.cabal" SAPIENS_TEST_UI_CACHE="$PWD/submodules/libs4/.cache" ruby submodules/libs4/ruby/bundle.rb exec rspec
```

The runner installs/enables the verifier only in its private fixture profile.
Use serial scenarios inside each desktop. Native headless Mutter is required for
scroll testing; X11-backed nested Mutter does not forward scroll here. Its absent
keyboard is initialized using a harmless F24 event after portal consent.
The 2× runner applies a temporary scale to a larger virtual monitor through
Mutter's public display API and verifies the GTK scale and actual input effects.
It uses physical monitor layout; this does not qualify mixed/fractional layouts.

Package lifecycle tests require a disposable filesystem with
`/run/sapiens-package-test`, `SAPIENS_TEST_LINUX_PACKAGE_LIFECYCLE=1` and
`SAPIENS_TEST_PACKAGE` pointing at the `.deb`. Supply
`SAPIENS_TEST_PREVIOUS_PACKAGE` to test an older package, upgrade, reinstall,
rollback and re-upgrade before purge; the test verifies installed versions and
preserves a user-data marker at each step. Never create the marker on a real
installation. The local Ubuntu images use real apt/dpkg with fakeroot ownership
emulation and share this machine's WSL2 kernel. They do not certify a separate
kernel, a registered WSL distribution, native hardware or enterprise enrollment.

The lifecycle test also creates a real fixture agent, completed turn and saved
file, pauses the corpus, and verifies them after each package change. It restores
an offline copy to the same data path and checks that completed work is not
replayed. This covers the tested development schemas, not unknown future migrations.

For repeatable local or CI evidence, use a new report directory:

```sh
sh environments/linux/qualify.sh headless .build/qualification-headless
SAPIENS_TEST_FIREFOX_EXECUTABLE=/absolute/path/to/firefox-153.6.0esr/firefox \
SAPIENS_TEST_FIREFOX_CHANNEL=moz-firefox \
  sh environments/linux/qualify.sh wayland .build/qualification-wayland
```

`xorg` selects the separate fallback suite. Desktop modes create an isolated
software desktop and install the verifier only in that fixture profile. Reports
contain OS/kernel, worktree status, tool versions, binary hashes, test output and
RSpec JSON. An exit status of zero can include pending examples; inspect the JSON.
The visible modes use Xephyr on the current X display, including WSLg;
`visible-wayland` runs nested Mutter inside it. Both show a desktop window; see
[the testing guide](../../docs/testing.md#native-desktop-tests) for commands and limits.
These fixtures do not certify a real login session. Hosted CI execution and signed
release publication remain pending; no workflow or artifact was published.

References: [AT-SPI compatibility notes](https://github.com/GNOME/at-spi2-core/blob/main/NEWS),
[WebKit GTK accessibility baseline](https://bugs.webkit.org/show_bug.cgi?id=227528),
[RemoteDesktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html).

## Retained qualification evidence

The [compatibility audit](AUDIT.md) summarizes the Ubuntu 22.04/24.04 results,
including the repaired desktop command routing and package workflow runs.
Machine-readable reports and logs remain under `.build/qualification-*/` and
`.build/linux-commands-evidence.json`; these local artifacts are not shipped.
The runs use isolated userspaces and software compositors on a stock WSL2 kernel,
not native hardware or registered enterprise installations.

Bundled Firefox encountered an intermittent launch SIGSEGV on Ubuntu 22.04.
The 20-cycle startup test reproduced it; subsequent 100-cycle success after the
separate headless service-leak fix does not establish a root cause or repair.
Original logs remain in `.build/linux-completion-virtual-monitor22.log` and
`.build/linux-browser-startup22.log`; the later run is
`.build/linux-firefox-nightly-clean-stress22.log`. Official Firefox ESR passed
separate startup and native input checks without changing the product browser pin.
One combined run also exceeded the desktop readiness timeout during concurrent
builds; its later success does not resolve that observation.

Package lifecycle evidence covers development upgrade/reinstall/rollback, a
populated corpus and offline restoration. Current artifact hashes belong in
the generated evidence records and SHA-256 sidecars, rather than this guide.
macOS/Windows native regression runs require those operating systems. The
remaining gates below prevent a production-ready claim.

## External release gates

| Required environment | Evidence required before release |
| --- | --- |
| Native Ubuntu 22.04/GNOME 42 and 24.04/GNOME 46; registered WSL2 desktops | Actual login, logout, lock/unlock and suspended/resumed sessions; mutation must fail while locked and after consent revocation |
| Physical and WSLg displays | GPU/software rendering, monitor hotplug, fractional/mixed scaling and keyboard layouts; verify actual click destinations and absence of unintended input |
| Enrolled enterprise WSL2 | Stock production Microsoft kernel, WSL1 disabled, default NAT and mirrored networking, corporate proxy/CA and locked extension policy; no kernel/network/policy workaround |
| Managed external browsers | Organization-approved versions and packaging, including Snap/distro builds; native discovery, focus, password rejection, draft verification and guarded submission against harmless fixtures |
| Enterprise deployment | Signed artifacts, approved installation, explicit extension consent, package rollback and existing-corpus compatibility |

Record OS/kernel, session/compositor, browser/package versions, policies, artifact
SHA-256, test seed and logs for each run. The built-in suites can run on those
machines, but this checkout has no authorized physical or enrolled test host.
Do not infer these results from nested GNOME, Xvfb or the userspace image tests.

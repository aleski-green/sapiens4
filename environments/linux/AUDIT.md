# Ubuntu compatibility audit — 2026-11-02

**Result: partial compatibility; source defects repaired, release gates remain.**
The current checkout cannot be described as supporting every Sapiens4 use case
on Ubuntu, in either desktop or headless mode. The generated-command workflow
tests cover desktop agent execution; component tests alone do not establish full
application compatibility.

Scope: repository-wide platform-boundary and workflow-coverage review of
`corpora/`, `app/`, `remote/`, `build/`, `environments/`, prompts, packaging and
specs; both initialized submodules (`blindly4`, `libs4`), their platform selection,
dependency manifests and test entrypoints. Vendored dependency implementations
were not individually audited. This is not exhaustive verification of every
function, third-party application or enterprise configuration.

Follow-up on 2026-11-02: the generated-command blocker was reproduced with
behavioral tests before changing `LinuxMain.hs`. It now forwards `control` and
`computer` to the sibling core executable before GTK setup, preserving arguments,
environment, standard streams and exit status. No business logic or native
macOS/Windows adapter changes were needed for this repair.

The rebuilt desktop package passed all four new command/workflow examples in
Ubuntu 22.04 and 24.04 userspaces, each in isolated Xorg and Wayland sessions.
They execute the actual generated shell commands, including inside provider turns,
and verify idle denial, exclusive ownership, cancellation and expired-run denial.
Evidence: `.build/linux-commands-package{22,24}-{xorg,wayland}.{json,log}`;
red evidence: `.build/linux-commands-red-final24.log` and
`.build/linux-command-forwarding-red.log`. These userspaces share the WSL2 kernel.
The rebuilt headless package and existing headless workflows also passed on both
userspaces: 28 passed each, with the separately gated apt lifecycle example pending
in each extracted-package run (`.build/linux-commands-headless{22,24}.{json,log}`).
The rebuilt artifacts are `.build/packages/sapiens4-cli-fixed-ubuntu-amd64.deb`
and `.build/packages/sapiens4-headless-cli-fixed-ubuntu-amd64.deb`.
Existing CLI/service/workflow/workspace regressions passed: 85 passed, two
Windows-only examples pending. Artifact hashes, userspace versions and test
summaries are recorded in `.build/linux-commands-evidence.json`.
The original evidence below is retained. Follow-up repairs add Linux Computer
diagnostics, shared Xorg UI coverage, accessible pairing codes, headless option
selection, Xorg foreground restoration and a Linux relay installation route.
The remaining capability and qualification boundaries are listed separately.

## Why macOS and Windows files changed

The only direct native adapter changes are one declaration in each of
`submodules/blindly4/macos/src/adapter.rs` and `windows/src/adapter.rs`:
`PASTE_USES_CLIPBOARD = true`. Linux declares it false. The shared paste operation
uses that capability to retain the existing clipboard capture, paste and restore
path on macOS/Windows, while Linux uses editable text or its explicit keyboard
transport. No existing native adapter implementation was deleted or rewritten.

There are no working-tree changes under Sapiens4's `environments/macos/` or
`environments/windows/`, or libs4's native Cocoa/Windows bindings. Shared changes
still affect their integration: Cabal host declarations/build flags, computer
launch dispatch, and the shared paste engine. The Windows executable-not-found
message also became generic in `corpora/work/Computer.hs`. Compatibility is the
intent; native macOS/Windows regression runs have not been performed here.

## Findings

### Desktop-generated agent commands (repaired)

`Population.setManifests` and `Management.prepare` publish the current executable
as the launcher. The desktop entrypoint previously rejected their `computer`
and `control` commands with its usage message, despite successful direct HTTP
and Blindly4 tests. `LinuxMain.hs` now forwards both commands before GTK setup.
`spec/linux_commands_spec.rb` exercises generated commands, provider turns,
ownership rejection, cancellation and expired runs. Original reproduction:
`.build/compatibility-audit/desktop-commands.log`.

### P1 — Existing UI workflow coverage excluded Linux (coverage added)

The original `spec/support/desktop.rb` accepted only macOS/Windows. The retained
pre-fix full-suite run contains **35 distinct examples** skipped
by that guard, including conversation/navigation, corpora switching, group UI,
remote pairing UI, accessibility and browser workflows. Some are intentionally
platform-specific. Linux-specific suites cover selected overlapping behaviors,
but do not replace the complete applicable UI workflow set.

The log mentions those skips twice; 70 matching lines are not 70 examples.
The complete run was 334 examples, **206 passed, 128 pending**, zero failures.
Other pending examples require opt-in Linux sessions/packages or another OS.
The original provider fixture used direct HTTP host-control requests. Generated
command actions now cover the desktop entrypoint separately.

Original evidence: `.build/linux-readiness-regression-final.log` and
`.build/compatibility-audit/skipped-ui.json`.

The shared fixture now uses the production GTK/WebKit shell on isolated Xorg,
and Xorg qualification includes applicable conversation, navigation, group,
corpora, relay, remote-pairing and workspace-browser scenarios. Linux observation
retries cover only replaced accessibility nodes; uncertain input is never replayed.
Platform-specific cases remain gated, including shared pointer-coordinate tests
on Wayland, which does not expose verified global accessibility coordinates.

These tests exposed and drove repairs to heading/static-text role mapping,
scroll-to-visible, nested-dialog coordinate verification, WebKit table-tree
observation, empty address-field editing, accessible matching codes and shell
reload. Inactive native guests are detached from the accessibility tree while
their pages and sessions are retained. Native GTK metadata remains available for
portal consent. WebKit radio controls that expose no native action use verified
physical clicks in the fixture.

### P2 — Linux Computer settings displayed macOS instructions (repaired)

The panel now distinguishes native AT-SPI from an owned headless browser. A
read-only `/api/computer` diagnostic reports backend presence, connectivity,
foreground verification and an existing Wayland input helper. Opening the panel
does not acquire computer ownership, start a turn or request portal consent.
Missing backends and diagnostic failures are shown without claiming readiness.
The sidebar identifies headless access as an owned browser. Behavioral API and
native UI tests cover both backends and missing installations.

### P2 — Headless automation is not full desktop or workspace-browser parity

`Bridge.cjs` exposes a deliberately smaller command set. `Browser.cjs` operates
one owned browser page and discovers main-frame controls. Frames, native app
launch, browser chrome, popup/additional-tab management, downloads, file-dialog
automation and desktop pointer input are not implemented by this bridge.
Single-selection controls now support `select --path PATH --value VALUE`, with
enabled-option validation before mutation and exact-value verification afterward.
Discovery exposes a bounded list of exact option values and marks omissions.
Chromium and Firefox tests cover Unicode options and unchanged values after
rejected disabled/missing options. Multiple-selection controls remain unsupported.
Browser profiles are temporary; authentication cookies do not survive restart.

The owned Playwright page is also separate from Sapiens workspace tabs.
`app/features/Workspace.purs` explicitly asks non-native clients to open the
desktop to browse web tabs. HTTP workspace state persistence does not prove
headless embedded-tab execution. Xvfb can run the native desktop as another
explicit mode; it does not add these capabilities to the headless bridge.

### P2 — Native input has application and session restrictions

The Linux adapter supports AT-SPI and Xorg/Wayland input, but external browser
editing requires explicit keyboard transport where writable AT-SPI is absent or
ineffective. That transport accepts printable ASCII up to 4096 bytes; Unicode
keyboard transfer is unsupported. Wayland additionally requires a single US
input source without XKB options. Native editable controls and headless browser
editing have separate Unicode coverage.

Wayland guarded mutation requires the optional GNOME foreground extension;
keyboard/pointer injection also requires a consented portal session. Xwayland
windows are rejected by that verifier. WSLg alone is not a GNOME Shell session.
Policy prohibiting the extension prevents this Wayland input path. Xorg remains
an explicit fallback, subject to organizational policy.

`Computer.captureForeground` now retains the originating desktop PID when it is
verified as frontmost. A real two-window Xorg test covers restoration after agent
computer use. Wayland compositors can decline AT-SPI activation; automatic
restoration there remains best effort and reports failure without bypassing
foreground checks. Native guest WebKit views deny permission requests;
camera/microphone/geolocation-dependent guest workflows
are not supported by that policy. Clipboard automation is unavailable in native
Blindly4 Linux. These are capability boundaries, not evidence of universal app
compatibility.

### P2 — Distribution and release qualification remains incomplete

Ubuntu 22.04 evidence uses an isolated official userspace on this machine's stock
WSL2 kernel. Ubuntu 24.04 desktop evidence uses software-rendered isolated GNOME.
Neither establishes physical Ubuntu desktop or separately enrolled WSL2 results.
Actual login/lock/unlock, hardware, mixed/fractional displays, IME/layouts, corporate
proxy/CA, NAT/mirrored networking and managed browser policies remain gates.

The desktop and headless packages are unsigned development artifacts. Native
upgrade/rollback and populated-corpus restore have local evidence; headless
install/reinstall/purge does not establish headless upgrade/rollback. Hosted Linux
CI, signed distribution and enterprise deployment remain pending. The relay
Dockerfile uses a different GHC baseline from the local build and was not built
in this audit. Docker is unavailable in this WSL distribution, so container
qualification remains open. The missing public `/linux` relay installation route
is repaired and covered by HTTP, manifest and native remote-pairing tests.

Earlier intermittent Firefox startup crashes and desktop readiness timeouts
remain recorded reliability risks despite later successful repeats. Do not
discard their failure logs or describe repeats as a proven root-cause fix.

## Module and workflow coverage

| Area | Ubuntu evidence | Boundary / outstanding work |
| --- | --- | --- |
| `corpora/state`: agents, SQLite, migrations, Notes, workspaces | Core HTTP/file/persistence contracts pass on this Linux host | Full business suite not separately qualified on every target installation |
| `corpora/work`: execution, delegation, groups, scheduling | Fixture-provider workflows, cancellation, recovery, ownership and real minute scheduling pass | Generated-command workflows covered; real authenticated provider and enterprise environment unqualified |
| `corpora/host`: service, API, assets, multiple corpora | Core contracts and launchers pass | Desktop CLI forwarding covered; real installation qualification pending |
| `app`: shell, conversations, work, groups, connections | Linux settings and applicable shared Xorg UI suites now have native coverage | Shared pointer-coordinate scenarios remain Xorg-only; headless web-tab limitation |
| `remote/control`, `protocol`, `relay` | Local encrypted pairing, receipts, retries/restart, Linux route and native pairing UI have coverage | Real devices, enterprise network and container release qualification incomplete |
| `environments/linux` headless | Fresh Chromium/Firefox bridge, launcher and workspace suite passes | Single-page scope and unsupported operations above |
| `environments/linux` desktop | Shared Xorg workflows, GTK/WebKit tabs, file selection, download guards and renderer recovery have local evidence | Real desktop qualification and broader application compatibility remain pending |
| `blindly4` shared engine and Linux adapter | Fresh 132 CLI examples pass; existing native fixture/input evidence | CLI suite is permission-free; it does not prove every application or Mac/Windows behavior |
| `blindly4` GNOME extension/input helper | Foreground, disable, overview and consent/pointer fixtures pass | Explicit consent required; no extension sandbox; actual lock/login and enrolled policy qualification pending |
| `libs4` | Linux Haskell/UI/Ruby/Node builds and package tests exercise pinned dependencies; native OS components remain gated | No claim of auditing every dependency implementation, vulnerability or supported external browser version |
| Build/package/source distribution | Existing source-build and Ubuntu package lifecycle evidence | Uncommitted submodule changes must be included in release revisions; CI/signing/release gates remain |

## Follow-up validation

All counts below distinguish passes from explicitly gated examples; they are
overlapping suites, not additive totals of unique tests.

| Run | Result | Evidence under `.build/` |
| --- | --- | --- |
| Full regression with documented dependency caches | 210 passed, 136 pending, zero failures | `audit-regression-cached.{json,log}` |
| Headless Chromium/Firefox, diagnostics and relay installation | 29 passed, 1 pending | `audit-headless-options.{json,log}` |
| Shared native Xorg UI workflows | 33 passed, 4 pending after corrective runs | `audit-shared-ui-final.{json,log}`, `audit-guest-ui.{json,log}` |
| Consolidated visible GNOME/X11 desktop and shared GUI suite through WSLg | 82 passed, 19 pending, zero failures in one run | `qualification-visible-xorg/{environment.json,results.json,run.log}` |
| Visible nested GNOME/Wayland native desktop suite through WSLg | 54 passed, 9 pending, zero failures | `qualification-visible-wayland-final/{environment.json,results.json,run.log}` |
| Native Xorg, including external Chromium/Firefox input | 49 passed, 14 pending | `audit-native-xorg-final.{json,log}` |
| Native Wayland, including consent and input guards | 39 passed, 8 pending | `audit-native-wayland-final.{json,log}` |
| Final Xorg guest lifecycle and pointer regressions | 18 passed | `audit-xorg-browser-final.{json,log}` |
| Final Wayland guest lifecycle and external-browser regressions | 27 passed, 1 pending | `audit-wayland-browsers.{json,log}` |
| Final exact empty-draft keyboard checks in Chromium/Firefox | 2 passed | `audit-empty-draft-final.{json,log}` |
| Blindly4 permission-free CLI | 132 passed | `audit-blindly-cli-final.log` |

The first shared UI run exposed five failures. The focused corrective run passed
all nine applicable scenarios and supersedes those five results; it does not
erase the original failures. GTK/WebKit fixture interactions use native
accessibility and verified pointer/keyboard input, without DOM assertions.
The later visible GNOME/X11 run provides a single clean consolidated desktop run:
101 examples in 20 minutes 26 seconds (seed 44396). It includes the shared GUI,
desktop lifecycle, guest browser, external Chromium/Firefox, generated-command,
foreground and native-input suites. The 19 pending cases require another OS,
Wayland, or a separate scaling/overview/policy fixture. A mapped WSLg window and
a rendered GUI screenshot are recorded under its `session/` directory. This is
a visible software-rendered nested session on Ubuntu 24.04/WSL2, not a GDM login
or physical Ubuntu desktop qualification.

The visible Wayland suite completed in 3 minutes 28 seconds (seed 20073): 54
passed, nine pending. It covers native desktop/guest lifecycle, Chromium/Firefox,
portal consent, foreground verification and guarded input. Shared GUI cases
requiring global coordinates remain X11-only; nested Mutter cannot qualify
pointer-scroll forwarding, and separate scale/overview/policy cases remain gated.
An initial directly nested Mutter window rendered black through WSLg with Mesa
X11 shared-memory errors. That run was interrupted and is not counted as visible
qualification (`qualification-visible-wayland/`). The runner now hosts both
visible modes in Xephyr; the corrected Wayland screenshot and mapped-parent
evidence are retained under `qualification-visible-wayland-final/session/`.
No application behavior changes were needed for these visible runs.

The Haskell desktop/UI builds, Rust debug/release builds, formatting and Clippy
checks also pass. Existing macOS/Windows native adapters were not run here.

The cold source-release test exceeded its 20-minute deadline while downloading
npm dependencies (`audit-regression-final.{json,log}`). The documented dependency
caches allow the source-only build and launch scenario to pass; cold installation
over a slow network remains unqualified. The complete cached regression ran 346
examples in 15 minutes 12 seconds (seed 49210), with zero failures; its 136 pending
examples require another platform or an explicit isolated-session/package opt-in.
The dedicated runs above exercise applicable Linux opt-ins separately. Earlier
failure logs are retained.

## Original evidence checked during this audit

- Fresh Ubuntu 24.04 headless run: **25 examples, 25 passed**, seed 8908;
  `.build/compatibility-audit/headless24/{environment.json,results.json,run.log}`.
- Fresh Blindly4 permission-free CLI run: **132 examples, 132 passed**, seed 55271;
  `.build/compatibility-audit/blindly-cli-corrected.log`. An initial invocation
  from the wrong working directory loaded the root spec helper and failed to
  load; the corrected invocation ran from the submodule.
- Original isolated desktop command reproduction, before the forwarding repair:
  `.build/compatibility-audit/desktop-commands.log`.
- Retained full regression: 334 examples, 206 passed, 128 pending, seed 64564.
- Retained Ubuntu 22.04 headless: 25 passed; Xorg: 57 examples, 44 passed,
  13 session-specific pending. Ubuntu 24.04 Wayland: 57 examples, 51 passed,
  6 session-specific pending. See `.build/qualification-*/results.json` and
  [NATIVE.md](NATIVE.md) for additional dedicated scale, policy and package runs.

The original audit changed documentation only. Follow-up changes repair the
source defects and add the coverage described above. Unsupported input/headless
operations, compositor-controlled Wayland activation, intermittent failures,
real desktop, enterprise-policy and signed-release qualification remain open.

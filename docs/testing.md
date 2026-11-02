# Testing

RSpec owns integration scenarios and assertions. Exercise public HTTP, processes,
files, relay traffic and native user interactions through Blindly4. Do not execute
JavaScript, inspect private application state or assert DOM/CSS implementation.
Fixtures use temporary data and controlled external model executables, never live
corpora or paid model calls. Dependencies stay in libs4.

Domain checks also run through public endpoints and saved installation fixtures:
invalid states and payloads, nonempty histories, retry cleanup, completion criteria,
and compatibility of stored data and native browser commands.

## Setup

Use GHC 9.14.1, Cabal 3.18.2, Ruby 3.4 and Node.js 22.5+:

```sh
git submodule update --init --recursive
ruby submodules/libs4/ruby/bundle.rb install
runghc build/Build.hs
ruby submodules/libs4/ruby/bundle.rb exec rspec
```

Scheduling cases use real minute pulses; `--tag '~slow'` is useful for iteration,
but run the complete suite before submitting. Source-release and platform build
checks are included. Set `SAPIENS_TEST_CABAL_CACHE` to the absolute path of an
existing `submodules/libs4/haskell/.cabal` cache to reuse dependencies in source-release tests.

## Native desktop tests

Use an unlocked desktop with accessibility permission. Run serially and avoid
interacting with fixture windows. On macOS:

```sh
./submodules/blindly4/macos/build.sh
ruby submodules/libs4/ruby/bundle.rb exec rspec
```

On Windows, use the same Haskell, Ruby and Node toolchains:

```powershell
git submodule update --init --recursive
ruby submodules/libs4/ruby/bundle.rb install
runghc build/Build.hs
$env:SAPIENS_TEST_CODEX = (Resolve-Path .build/bin/sapiens-provider.exe).Path
$env:SAPIENS_TEST_BLINDLY4 = 'C:\path\to\blindly4.exe'
ruby submodules/libs4/ruby/bundle.rb exec rspec
```

Set `SAPIENS_TEST_WINDOWS_PACKAGE` to a package built with `environments/windows/build.ps1`
to include packaged-runtime checks. Test ARM64 and x64 on matching systems.
Use `--tag desktop` for focused UI runs. Desktop tests automatically use the bundled
Blindly4 build on macOS and Windows; `SAPIENS_TEST_BLINDLY4` optionally selects a
different executable. A missing driver or a permission or interaction error fails
the test instead of silently skipping it. Unsupported platforms and Windows-only
contracts remain pending on macOS.
Failed desktop scenarios write accessible content to `tmp/desktop-failure.txt`
and a separate accessibility-tree JSON file under `.build/` for each failed example.

On Linux, build with `runghc build/Build.hs --desktop` and run
`spec/linux_commands_spec.rb` inside `spec/support/gnome-session.sh`. Set
`SAPIENS_TEST_XORG=1` for isolated Xorg or `SAPIENS_TEST_HEADLESS=1` for isolated
Wayland. These tests start a temporary desktop corpus and execute its generated
control/computer commands, including inside fixture-provider turns, checking
exclusive ownership, cancellation and expired runs. The forwarding-only example
also runs without a display. `environments/linux/qualify.sh` includes this suite.

Shared UI workflows also run on isolated Linux Xorg. Build the Linux Blindly4
driver, then run:

```sh
SAPIENS_TEST_XORG=1 SAPIENS_TEST_GNOME_FOREGROUND=1 \
  spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec --tag desktop
```

The fixture uses the production GTK/WebKit shell and browser
adapter. Xorg qualification includes the applicable shared suites. These tests
use explicit ASCII keyboard transport for WebKit editors; encoded file URLs
exercise files with Unicode paths. Native editable-control and file-chooser
Unicode coverage remains in the Linux suites. Shared pointer-coordinate tests
remain gated on Wayland, where global accessibility coordinates are unavailable.
Set `SAPIENS_TEST_GNOME_LOGS` to preserve session diagnostics in a separate directory.

For a visible nested GNOME desktop on an existing X display (including WSLg), use:

```sh
sh environments/linux/qualify.sh visible-xorg .build/qualification-visible-xorg
sh environments/linux/qualify.sh visible-wayland .build/qualification-visible-wayland
```

Run these serially and leave the test window alone. Both visible modes use
Xephyr to display the desktop; this also avoids Mesa shared-memory rendering
failures when nested Mutter connects directly to WSLg. Visible Xorg includes
the shared GUI workflows; visible Wayland runs nested Mutter and the applicable
Linux suites. Neither mode uses Xvfb or a headless compositor.
Both use temporary desktop settings and data, and preserve logs in the new report
directory. Nested Wayland cannot qualify pointer-scroll forwarding; shared tests
requiring global coordinates remain Xorg-only. These runs do not establish native
hardware, GDM login or physical-display coverage.

To exercise a desktop package, extract it with `dpkg-deb --extract` and set
`SAPIENS_TEST_LINUX_RUNTIME` to the extracted `opt/sapiens4` directory before
running the same suite. Repeat in Ubuntu 22.04 and 24.04 userspaces. Check the
headless package separately with `SAPIENS_TEST_HEADLESS_PACKAGE` and
`spec/linux_headless_package_spec.rb`; enable `SAPIENS_TEST_HEADLESS_BROWSERS=1`
for the existing bridge, external-browser and launcher scenarios.

Use mouse clicks to establish that controls are reachable; accessibility
invocation alone can activate offscreen controls. Rediscover moving targets and
verify editor focus and exact values. Retry only observations or rejections known
to occur before input; never replay an action after an uncertain outcome.

## Coverage limits

The macOS and Linux fixtures run WebKit with the production browser adapter;
Windows runs MainWindow/WebView2. Remote-browser and HTTP-proxy window cases
currently require macOS or Linux Xorg. Reload tests do not establish persistence
across an actual app quit/upgrade.
Validate mobile installation, camera pairing, background/resume, offline launch,
updates, keyboard/rotation and touch behavior on real devices. Visually compare
appearance changes; behavioral tests do not prove styling equivalence.

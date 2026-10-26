# Testing

RSpec owns all scenarios and assertions. Exercise public HTTP, processes, files,
relay traffic and native user interactions through Blindly4. Do not execute
JavaScript, inspect private application state or assert DOM/CSS implementation.
Fixtures use temporary data and controlled external model executables, never live
corpora or paid model calls. Dependencies stay in libs4.

## Setup

Use Ruby 3.4, Python 3.11+, Node.js 22.5+ and npm:

```sh
git submodule update --init --recursive
ruby libs4/ruby/bundle.rb install
python3 -m venv libs4/python/.venv
libs4/python/.venv/bin/python -m pip install -r libs4/python/remote-requirements.txt
python3 web/shell/build.py
export SAPIENS_PYTHON="$PWD/libs4/python/.venv/bin/python"
ruby libs4/ruby/bundle.rb exec rspec
```

Set `SAPIENS_PYTHON` to override the test interpreter. Scheduling cases use real
minute pulses; `--tag '~slow'` is useful for iteration, but run the complete suite
before submitting. Source-release and platform build checks are included.

## Native desktop tests

Use an unlocked desktop with accessibility permission. Run serially and avoid
interacting with fixture windows. On macOS:

```sh
./blindly4/macos/build.sh
export SAPIENS_TEST_BLINDLY4="$PWD/blindly4/.build/release/blindly4"
ruby libs4/ruby/bundle.rb exec rspec
```

On Windows, use .NET 10, Ruby 3.4, Python 3.11+, Node.js 22.5+ and npm:

```powershell
git submodule update --init --recursive
ruby libs4/ruby/bundle.rb install
python -m venv libs4/python/.venv
$env:SAPIENS_PYTHON = (Resolve-Path libs4/python/.venv/Scripts/python.exe).Path
& $env:SAPIENS_PYTHON -m pip install -r libs4/python/remote-requirements.txt
& $env:SAPIENS_PYTHON web/shell/build.py
dotnet build spec/support/windows/CodexFixture.csproj -o tmp/codex-fixture
$env:SAPIENS_TEST_CODEX = (Resolve-Path tmp/codex-fixture/CodexFixture.exe).Path
$env:SAPIENS_TEST_BLINDLY4 = 'C:\path\to\blindly4.exe'
ruby libs4/ruby/bundle.rb exec rspec
```

Set `SAPIENS_TEST_WINDOWS_PACKAGE` to a package built with `windows/build.ps1`
to include packaged-runtime checks. Test ARM64 and x64 on matching systems.
Use `--tag desktop` for focused UI runs. Missing platform configuration produces
pending cases; configured permission and interaction errors are failures.
Failed desktop scenarios write accessible content to `tmp/desktop-failure.txt`.

Use mouse clicks to establish that controls are reachable; accessibility
invocation alone can activate offscreen controls. Rediscover moving targets and
verify editor focus and exact values. Retry only observations or rejections known
to occur before input; never replay an action after an uncertain outcome.

## Coverage limits

The macOS fixture runs WebKit with the production browser adapter; Windows runs
MainWindow/WebView2. Remote-browser and HTTP-proxy window cases currently require
macOS. Reload tests do not establish persistence across an actual app quit/upgrade.
Validate mobile installation, camera pairing, background/resume, offline launch,
updates, keyboard/rotation and touch behavior on real devices. Visually compare
appearance changes; behavioral tests do not prove styling equivalence.

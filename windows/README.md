# Sapiens4 for Windows

This modified fork adds Windows support to Sapiens4 while retaining the macOS app. The package includes Sapiens4, Blindly4 and libs4 licensing documents in `license/`, `runtime/blindly4/license/` and `runtime/libs4/license/`; see those files for their respective terms.

Extract the whole portable package, then double-click **Sapiens4.exe**. Use `win-arm64` on ARM PCs or `win-x64` on Intel/AMD PCs. The package contains Python, .NET and Blindly4; it does not require WSL or administrator access. Requires Windows 10/11 and Microsoft Edge WebView2 Runtime (included with Windows 11; install the Evergreen Runtime from Microsoft on systems without it).

Chat uses your authenticated Codex CLI 0.156.1 or newer. The desktop app's installed CLI and native npm Codex binaries are discovered automatically. To select another installation, set `SAPIENS_CODEX_BINARY` to its full `codex.exe` path. Sign in using `codex login` before chatting. No credentials are included in this package.

User data is stored at `%LOCALAPPDATA%\Sapiens4`, separately from the application files. The native window supports Chat, Notes, attachments, tasks and per-Sapi browser tabs, bookmarks and zoom. Browser websites have separate profiles and no access to the desktop app bridge. Closing the app stops its local server and cancels active model processes; saved conversations remain recoverable.

The Windows executable, taskbar and window use the workspace logo. The native title bar shows Sapiens4 so the window is identifiable to users and accessibility tools. The browser favicon and running window icon use a dark background in dark mode and a light background in light mode. The native title bar follows the same theme, including when the workspace is hidden. Windows 11 also matches the header's background and text colors. Browser blank pages and plain-text documents follow the app theme; websites receive the same light/dark preference and retain their own styles.

The first build is unsigned. No automatic updater or installer is included: replace the extracted application directory to update it, keeping the data directory intact.

## Source development

Install Python 3.9+, Git, .NET SDK 10, stable Rust and MSVC C++ build tools. Install
the Rust target for your package (`rustup target add aarch64-pc-windows-msvc` or
`rustup target add x86_64-pc-windows-msvc`). Then:

```powershell
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
.\start.ps1 -Open
```

`start.ps1` builds Blindly4 and starts the web UI on port 4174. `-SkipBuild` reuses an existing binary.

Build the portable desktop package:

```powershell
.\windows\build.ps1 -Runtime win-arm64
# or -Runtime win-x64
.\.build\Sapiens4-win-arm64\Sapiens4.exe
```

The build downloads CPython 3.13.9 from python.org and verifies a pinned SHA-256. A build-time Python with pip installs CLI and encrypted remote-client dependencies as wheels for the selected architecture into the embedded runtime; the finished package needs no separate Python installation. Use `-BuildPython PATH` to select that build interpreter. The relay server's aiohttp dependency is separate. NuGet restores the pinned WebView2 SDK; WebView2 uses the locally installed Evergreen Runtime. To run a desktop development build, set `SAPIENS_PYTHON` to Python's full path and `SAPIENS_RUNTIME_DIR` to the repository root. An installed LLVM-MinGW Rust toolchain can be selected with `-BlindlyToolchain gnullvm`; MSVC remains the default.

`AppIcon.ico` and `AppIconDark.ico` contain nine resolutions from 16 to 256 pixels, rendered from the SVG in `web/shell/bootstrap.js` with light and dark backgrounds. After changing that favicon, regenerate both with `node windows/icon.cjs` (requires the `sharp` Node package). Normal Windows builds embed the checked-in icons and do not need Node. Explorer and pinned shortcuts retain the default light icon; the running window switches icons with the app theme.

## Tests

```powershell
$env:PYTHONUTF8 = '1'
ruby libs4/ruby/bundle.rb install
python -m pip install -r libs4/python/remote-requirements.txt
npm ci --prefix libs4 --ignore-scripts
dotnet build spec/support/windows/CodexFixture.csproj -o tmp/codex-fixture
$env:SAPIENS_TEST_CODEX = (Resolve-Path tmp/codex-fixture/CodexFixture.exe).Path
$env:SAPIENS_PYTHON = 'python'
ruby libs4/ruby/bundle.rb exec rspec --tag '~windows'
```

The executable also accepts `--smoke-report PATH --data-dir TEMP_DIRECTORY` to launch a real WebView2 window, verify the rendered app, save a JSON result and PNG, then close. Use an empty test data directory. The Blindly4 repository documents its permission-free and interactive integration suites.

To include the native RSpec contract in a local run, build the portable desktop package and set `SAPIENS_TEST_WINDOWS_PACKAGE` to its directory. See [Testing](../documentation/testing.md). macOS and POSIX-only cases are explicitly skipped on Windows; no security settings are changed to run tests.

## Desktop access

Blindly4 uses native Windows UI Automation and SendInput. Its command interface retains AX-style role names for compatibility. Desktop commands require an unlocked interactive session, exposed accessibility controls and matching privilege levels. Elevated apps and secure desktops are not supported. Draft guards fail closed when a control cannot expose its exact value. Serialize complete desktop workflows.

Overrides: `SAPIENS_DATA_DIR`, `SAPIENS_BLINDLY_BINARY`, `SAPIENS_CODEX_BINARY`, `SAPIENS_CODEX_MODEL`, `SAPIENS_CODEX_REASONING_EFFORT`. The desktop uses a free loopback port.

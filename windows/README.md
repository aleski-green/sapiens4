# Sapiens4 for Windows

This modified fork adds Windows support to Sapiens4 while retaining the macOS app. The package includes Sapiens4 and Blindly4 licensing documents in `license/` and `runtime/blindly4/license/`; see those files for their respective terms.

Extract the whole portable package, then double-click **Sapiens4.exe**. Use `win-arm64` on ARM PCs or `win-x64` on Intel/AMD PCs. The package contains Python, .NET and Blindly4; it does not require WSL or administrator access. Requires Windows 10/11 and Microsoft Edge WebView2 Runtime (included with Windows 11; install the Evergreen Runtime from Microsoft on systems without it).

Chat uses your authenticated Codex CLI 0.156.1 or newer. The desktop app's installed CLI and native npm Codex binaries are discovered automatically. To select another installation, set `SAPIENS_CODEX_BINARY` to its full `codex.exe` path. Sign in using `codex login` before chatting. No credentials are included in this package.

User data is stored at `%LOCALAPPDATA%\Sapiens4`, separately from the application files. The native window supports Chat, Notes, attachments, tasks and per-Sapi browser tabs, bookmarks and zoom. Browser websites have separate profiles and no access to the desktop app bridge. Closing the app stops its local server and cancels active model processes; saved conversations remain recoverable.

The Windows executable, taskbar and window use the workspace logo. The native title bar displays `Sapiens4` so Win32 tools, including Blindly, can discover the window and request a normal foreground return. A blank native caption is excluded by Blindly's current window discovery even when the accessibility name is present. This title does not bypass Windows foreground restrictions or any input guard. The browser favicon and running window icon use a dark background in dark mode and a light background in light mode. The native title bar follows the same theme, including when the workspace is hidden. Windows 11 also matches the header's background and text colors. Browser blank pages and plain-text documents follow the app theme; websites receive the same light/dark preference and retain their own styles.

The first build is unsigned. No automatic updater or installer is included: replace the extracted application directory to update it, keeping the data directory intact.

## Source development

Install Python 3.9+, Git and .NET SDK 10. Then:

```powershell
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
.\start.ps1 -Open
```

`start.ps1` builds Blindly4 and starts the web UI on port 4174. `-SkipBuild` reuses an existing binary. `sapiens4.cmd status` and other terminal commands work with the running app. Interactive terminal mode additionally requires `pip install -r requirements-cli.txt` in a regular Python installation.

Build the portable desktop package:

```powershell
.\windows\build.ps1 -Runtime win-arm64
# or -Runtime win-x64
.\.build\Sapiens4-win-arm64\Sapiens4.exe
```

The build downloads CPython 3.13.9 from python.org and verifies a pinned SHA-256. NuGet restores the pinned WebView2 SDK; WebView2 uses the locally installed Evergreen Runtime. To run a desktop development build, set `SAPIENS_PYTHON` to Python's full path and `SAPIENS_RUNTIME_DIR` to the repository root.

`AppIcon.ico` and `AppIconDark.ico` contain nine resolutions from 16 to 256 pixels, rendered from the SVG in `web/shell/bootstrap.js` with light and dark backgrounds. After changing that favicon, regenerate both with `node windows/icon.cjs` (requires the `sharp` Node package). Normal Windows builds embed the checked-in icons and do not need Node. Explorer and pinned shortcuts retain the default light icon; the running window switches icons with the app theme.

## Tests

```powershell
$env:PYTHONUTF8 = '1'
python -m pip install -r tests/requirements.txt
python -m unittest discover -s tests -v
dotnet build windows/Sapiens4.csproj -c Release
.\windows\bin\Release\net10.0-windows\Sapiens4.exe --self-test navigation-results.json
```

The executable also accepts `--smoke-report PATH --data-dir TEMP_DIRECTORY` to launch a real WebView2 window, verify the rendered app, save a JSON result and PNG, then close. Use an empty test data directory. The Blindly4 repository documents its permission-free and interactive integration suites.

macOS-only tests remain in macOS/Linux CI. Symlink tests report a skip if Windows denies symlink creation; no system security settings are changed to run tests.

### Window-title fix validation (2026-10-14)

The Windows x64 package with the native-title fix compiled successfully. Its new
self-test reads the actual Win32 caption without showing the window or starting
the host. Execution of this rebuilt package remains unverified on the reporting
laptop: Windows Application event 1026 reported that Application Control blocked
`Sapiens4.dll` with error `0x800711C7` before startup. No security policy was changed.
The new self-test and the native Sapiens-to-Chrome-to-Sapiens foreground sequence
still need execution on a machine that permits the build.

Before the title change, the UTF-8-fixed build passed 20 focused Python tests,
18 desktop self-tests, and the live WebView2 smoke test (including native/group
browser checks and 12 theme checks). These earlier results do not validate the
new title test or establish reliable unattended foreground activation.

## Desktop access

Blindly4 uses native Windows UI Automation and SendInput. Its command interface retains AX-style role names for compatibility. Desktop commands require an unlocked interactive session, exposed accessibility controls and matching privilege levels. Elevated apps and secure desktops are not supported. Draft guards fail closed when a control cannot expose its exact value. Serialize complete desktop workflows.

Overrides: `SAPIENS_DATA_DIR`, `SAPIENS_BLINDLY_BINARY`, `SAPIENS_CODEX_BINARY`, `SAPIENS_CODEX_MODEL`, `SAPIENS_CODEX_REASONING_EFFORT`. The desktop uses a free loopback port and saves it in the data directory for the terminal client.

The managed computer helper emits UTF-8 on stdout and stderr, including when
started from a shell whose default Python pipe encoding is a legacy code page.
Do not strip Unicode characters from application labels to work around encoding
errors. `tests/test_computer_encoding.py` covers this boundary without desktop input.

Windows can refuse a background process's foreground-activation request. This is
different from a missing accessibility permission. For a user-requested web task,
the supported `blindly open --url <task-url>` command can open the intended page;
then freshly verify the application, URL and foreground PID before input. Opening
a URL does not guarantee focus. If input is still blocked, stop and ask the user
to bring the target forward and leave it active. Never disable the foreground or
draft guards, and do not count a completed model reply as a completed UI task.

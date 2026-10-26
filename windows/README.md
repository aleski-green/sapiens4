# Sapiens4 for Windows

Extract the whole portable package and run **Sapiens4.exe**. Choose `win-arm64`
for ARM PCs or `win-x64` for Intel/AMD. Requires Windows 10/11 and Microsoft Edge
WebView2 Evergreen Runtime. Python, .NET and Blindly4 are bundled; WSL and
administrator access are not required.

Chat requires authenticated Codex CLI 0.156.1+. Run `codex login`; installed CLI
and native npm binaries are discovered automatically. Set `SAPIENS_CODEX_BINARY`
to a full executable path to override discovery.

Data lives in `%LOCALAPPDATA%\Sapiens4`, separate from the application. Closing the
app stops its server and cancels active calls. The package is unsigned and has no
automatic updater: replace the application directory while retaining the data.
Licenses ship in `license/`, `runtime/blindly4/license/` and `runtime/libs4/license/`.

## Build from source

Install Python 3.9+, Node.js 22.5+, npm, Git, .NET SDK 10, stable Rust and MSVC C++
build tools. Add the Rust target matching your package:
`aarch64-pc-windows-msvc` or `x86_64-pc-windows-msvc`.
On ARM64, use x64 Node for the pinned PureScript compiler under emulation;
the finished package still targets ARM64.

```powershell
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
.\start.ps1 -Open
.\windows\build.ps1 -Runtime win-arm64
# Use -Runtime win-x64 for Intel/AMD.
.\.build\Sapiens4-win-arm64\Sapiens4.exe
```

`start.ps1` builds Blindly4 and the UI; `-SkipBuild` reuses the existing binary.
Packaging verifies the pinned CPython download and installs dependency wheels for
the selected architecture. Use `-BuildPython PATH` to select the build interpreter
or `-BlindlyToolchain gnullvm` for an installed LLVM-MinGW toolchain. NuGet restores
the pinned WebView2 SDK. Installed packages do not need Node or a separate Python.

For desktop development, set `SAPIENS_PYTHON` to Python's full path and
`SAPIENS_RUNTIME_DIR` to the repository root. Other overrides are
`SAPIENS_DATA_DIR`, `SAPIENS_BLINDLY_BINARY`, `SAPIENS_CODEX_BINARY`,
`SAPIENS_CODEX_MODEL` and `SAPIENS_CODEX_REASONING_EFFORT`.
Regenerate the checked-in icons after favicon changes with `python windows/icon.py`.

## Tests and desktop access

Follow [Testing](../documentation/testing.md). Set `SAPIENS_TEST_WINDOWS_PACKAGE`
to the built package directory for packaged-runtime tests; run ARM64 and x64 on
matching machines. Tests use temporary data and controlled model executables.

Blindly4 requires an unlocked interactive desktop, accessible controls and matching
privilege levels. Elevated apps and secure desktops are unsupported. Exact-value
guards must remain enabled, and desktop workflows must run serially.

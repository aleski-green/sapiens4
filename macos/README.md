# Sapiens4 for macOS

An AppKit/WebKit window with its own Dock icon and managed updates. Requires macOS 13+, installed Command Line Tools, Python 3.9+, Git and authenticated Codex CLI. No full Xcode installation or extra Python packages are needed. Set up the repository and build Blindly4 first using the normal project setup.

## Install

From the repository root:

```sh
python3 macos/install.py
open "$HOME/Applications/Sapiens4.app"
```

Run the installer with the Python runtime you want the app to use. It records that executable and PATH. Closing or quitting the desktop window leaves the server running so agents and scheduled jobs continue. Right-click the Dock icon → Options → Keep in Dock. The server starts when the app opens; this does not install a login item.

For an unmanaged development launcher without update controls, run `./macos/build.sh`; its output is `.build/macos/Sapiens4.app`. Set `SAPIENS_PYTHON` to choose its runtime.

## Updates

The managed app checks `https://github.com/aleski-green/sapiens4.git`, branch `main`, at launch and every hour while the app is running and the Mac is awake. Checking and up-to-date states use no workspace space. An available update shows a compact banner with **Update now** and **Dismiss**; dismissing it stays effective for that revision across checks and launches. Installation progress stays visible until completion, and errors have a dismissible retry banner. **Sapiens4 → Check for Updates…** remains available for manual checks and reveals a previously dismissed update. The Dock uses one static bundle icon with no update badge or runtime icon replacement. Checks do not automatically apply updates.

Click **Update now** once:

The updater probes installed macOS SDKs for compiler compatibility. If SwiftPM
fails with the known missing `llbuild` symbol, it compiles the dependency-free
Blindly4 target directly and runs its self-test. The desktop build uses the same
compatible SDK. This does not change system developer-tool settings; other build
failures still leave the running version intact.

1. Download the advertised main revision into a new release directory, fetch the pinned submodules recursively, and build Blindly4. If main includes the compatible desktop build, build and validate that bundle too. Build failures leave the running version alone.
2. Wait until active and queued work finishes. The update helper can continue waiting if the desktop window closes. Reopening the app shows its persisted progress; an installation lock prevents overlapping updates.
3. Gracefully stop the owned local backend, retaining its existing data directory. A managed backend keeps host-control available while any run that raced with the idle check finishes. No force kill is used.
4. Back up the complete stopped state directory, including SQLite/WAL files, AgentPy state, preferences, artifacts and logs.
5. Start the candidate with its worker and workspace requests held. Verify the local health response and the candidate process identity. Only commit the new release and enable jobs after verification. The desktop window waits for backend activation before loading or reloading the workspace, so it cannot get stuck showing the temporary verification response.
6. Restore the previous code and saved state if startup fails before commit. Incomplete transactions are recovered at the next launch/update. Failed candidate state is retained for diagnosis. Recovery clears the rollback journal before restarting workers, so a later helper crash cannot replay that backup over new work. After jobs have been enabled, automatic data rollback is deliberately avoided because jobs may already have produced external effects.
7. When main contains desktop sources, atomically exchange the desktop bundles, retain the previous bundle, and reopen the window. The desktop revision is recorded separately after both the bundle and update helper are installed. If this step fails, checking for updates offers **Update now** again even if the backend already matches main. Retrying that revision only installs the desktop app; it does not stop the backend or restore its state. Until those sources land on main, backend/submodule updates preserve the installed wrapper.

The status bar shows the target commit. Checks compare exact revisions, so a rewritten main is also offered as an update. There is no forced reset or deletion of the development checkout. Updates execute code from the configured upstream after your click, using your normal account permissions.

## Locations and preservation

- App: `~/Applications/Sapiens4.app`
- Managed releases, current-version pointer, update status, backups and logs: `~/Library/Application Support/Sapiens4/`
- Data: the existing repository's `.sapiens4` directory, recorded explicitly in the managed `config.json`. Keeping this path preserves existing absolute artifact references. It is outside all replaceable release directories. Do not delete or move that data directory.
- Logs: managed `desktop-server.log` and `updater.log`.

The first install snapshots the current checkout and pinned submodules into an independent release. A server already running from the original checkout is reused until the first approved update or a later cold start. Reinstallation preserves the managed release pointer and saved data. Releases and backups are retained; there is no automatic cleanup policy yet.

The recorded Python executable must remain installed. The app is locally ad-hoc signed, not notarized or portable. Native file selection, normal editing shortcuts and external links are supported. External links open in the default browser; the workspace's WebKit storage does not inherit browser sign-ins. The Dock icon is rendered from the exact favicon SVG in `web/bootstrap.js`.

## Verification

```sh
python3 -m unittest tests.test_desktop_updater -v
codesign --verify --strict .build/macos/Sapiens4.app
plutil -lint .build/macos/Sapiens4.app/Contents/Info.plist
```

Tests cover notification-only checks, malformed remote revisions, waiting for work, failed builds, state backup/restore, committed-transaction recovery, refusing unrelated processes, atomic bundle exchange, and an actual temporary-port backend held until activation. The integration test uses isolated data and sends no agent prompts. A full GitHub update smoke check should also use a separate port and disposable data; never interrupt a user's live jobs just to test the updater.

# Sapiens4 for macOS

An AppKit/WebKit window with a Dock icon. Requires macOS 13+, Command Line Tools,
stable Rust, Python 3.9+, Git and authenticated Codex CLI 0.156.1 or newer.

## Build and open

From the repository root:

```sh
git submodule update --init --recursive
./blindly4/macos/build.sh
./macos/build.sh
open .build/macos/Sapiens4.app
```

Set `SAPIENS_PYTHON` to choose Python. The build records that executable, PATH,
repository location and data directory. Keep the checkout and Python in place.
The app starts the local backend when needed; closing or quitting its window
leaves the backend running so conversations can finish. It installs no login item.
Right-click the Dock icon → Options → Keep in Dock.

Data defaults to the checkout's `.sapiens4` directory. Set `SAPIENS_DATA_DIR` when
building to retain an existing data location. The backend log is
`desktop-server.log` inside that directory. Builds do not move or delete data.

## Manual version changes

Desktop update checks, update controls, managed installation, and automatic
backup/rollback are removed. Build and open each new version manually. The
app is locally ad-hoc signed, not notarized or portable.

For an existing managed installation, first let active work finish, quit the old
app, and gracefully stop its backend before opening the replacement. Reuse the
exact data directory recorded by the old installation:

```sh
SAPIENS_DATA_DIR="$(python3 -c 'import json,pathlib; print(json.loads((pathlib.Path.home()/"Library/Application Support/Sapiens4/config.json").read_text())["data"])')" ./macos/build.sh
open .build/macos/Sapiens4.app
```

Keep the old data directory and backups. The new build does not read or modify
old managed releases, and an old Dock shortcut still opens the old app; pin the
new app instead. Never run two backends against the same data directory.

## Workspace and verification

Native tabs support links, local files, bookmarks, back/forward, reload and zoom.
WebKit tabs keep their own browser sessions. File selection, editing shortcuts,
external links, themes and the favicon-derived Dock icon remain available.

```sh
ruby libs4/ruby/bundle.rb exec rspec spec/distribution_spec.rb spec/workspace_accessibility_spec.rb
codesign --verify --strict .build/macos/Sapiens4.app
```

Tests use temporary data and controlled model executables; see
[coverage and platform requirements](../documentation/testing.md).

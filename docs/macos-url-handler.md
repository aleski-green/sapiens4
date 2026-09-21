# macOS workspace shortcut

Start Sapiens4 normally on macOS:

```sh
./start.sh --port 4175
```

Enter `sapi4://corpora` in your browser's address bar, or run:

```sh
open 'sapi4://corpora'
```

Both `./start.sh` and `python3 -m sapiens` automatically install/update the
per-user handler on macOS and register the server's actual bound port. There
is no fixed port in the handler: `--port 4175`, the default port, and `--port 0`
(an available port chosen by macOS) all work.

The handler reads `~/Library/Application Support/Sapiens4/workspace.plist`,
checks that the registered process and its health endpoint are available, and
opens `http://127.0.0.1:<current-port>/workspace/` in your default browser.
Sapiens4 must already be running. If it isn't, the handler displays a brief
message asking you to start it. The browser may ask permission to open
Sapi4Handler. The destination's normal HTTP address appears after opening.

When several instances use different data directories, the most recently
started instance is the shortcut's destination. Closing an older instance
does not remove the newer registration. After closing the newest instance,
restart the instance you want to make the shortcut's destination.

`sapi4://corpora/` and `sapi4:corpora` are also accepted. Other destinations are
rejected. The handler does not read or modify workspace data.

The app lives at `~/Applications/Sapi4Handler.app`. Its source and installer
live in `scripts/`. You can run `bash scripts/install-macos-url-handler.sh`
manually to install/update the handler, but only server startup registers a
destination. A handler installation failure is logged and does not prevent
the HTTP server from starting. Other platforms skip this macOS integration.

To uninstall, unregister it with the command below, then move the app to
Trash. The next macOS server startup will install it again.

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$HOME/Applications/Sapi4Handler.app"
```

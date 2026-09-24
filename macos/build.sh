#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON=${SAPIENS_PYTHON:-$(command -v python3)}
BUILD="$ROOT/.build/macos"
APP="$BUILD/Sapiens4.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/AppIcon.iconset" "$BUILD/module-cache"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 9), "Python 3.9+ required"'
xcrun swiftc -module-cache-path "$BUILD/module-cache" -O -framework Cocoa -framework WebKit "$ROOT/macos/Sapiens4.swift" "$ROOT/macos/NavigationPolicy.swift" "$ROOT/macos/ServerReadiness.swift" -o "$APP/Contents/MacOS/Sapiens4"
xcrun swiftc -module-cache-path "$BUILD/module-cache" -framework Cocoa "$ROOT/macos/icon.swift" -o "$BUILD/make-icon"
# Extract the browser favicon so the desktop icon cannot drift from its source.
"$PYTHON" - "$ROOT/web/bootstrap.js" "$BUILD/favicon.svg" <<'PYICON'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"encodeURIComponent\('(<svg[^\n]+</svg>)'\)", source)
if not match:
    raise SystemExit("Workspace favicon SVG was not found in web/bootstrap.js")
pathlib.Path(sys.argv[2]).write_text(match.group(1))
PYICON
"$BUILD/make-icon" "$BUILD/AppIcon.iconset" "$BUILD/favicon.svg"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
"$PYTHON" - "$APP" "$ROOT" "$PYTHON" "$PATH" <<'PY'
import pathlib, plistlib, sys
import os, subprocess
app, root, python, path = sys.argv[1:]
contents = pathlib.Path(app) / 'Contents'
info = dict(CFBundleIdentifier='com.sapiens4.desktop', CFBundleName='Sapiens4', CFBundleDisplayName='Sapiens4', CFBundleExecutable='Sapiens4', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', CFBundleIconFile='AppIcon', NSHighResolutionCapable=True, LSMinimumSystemVersion='13.0', NSAppTransportSecurity={'NSAllowsLocalNetworking': True}, NSHumanReadableCopyright='Sapiens4 local desktop launcher')
info['SapiensDesktopRevision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
(contents / 'Resources' / 'Launcher.plist').write_bytes(plistlib.dumps(dict(Repository=root, Python=python, Path=path, **({'ManagedHome': os.environ['SAPIENS_DESKTOP_HOME']} if os.environ.get('SAPIENS_DESKTOP_HOME') else {}))))
PY
cp "$ROOT/macos/updater.py" "$APP/Contents/Resources/updater.py"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"

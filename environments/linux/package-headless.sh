#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ "$#" -ne 1 ]; then echo 'Usage: package-headless.sh OUTPUT.deb' >&2; exit 64; fi
if [ "$(uname -m)" != x86_64 ]; then echo 'Only amd64 is qualified for this package.' >&2; exit 64; fi
build=${SAPIENS_LINUX_BUILD_DIR:-$root/.build}
node=$(node -p 'process.execPath')
for binary in "$build/bin/sapiens4" "$build/domain/sapiens-domain" "$node"; do
    required=$(objdump -T "$binary" | sed -n 's/.*(GLIBC_\([0-9.]*\)).*/\1/p' | sort -V | tail -1)
    newest=$(printf '%s\n2.35\n' "$required" | sort -V | tail -1)
    if [ -z "$required" ] || [ "$newest" != 2.35 ]; then
        echo "Build $binary against Ubuntu 22.04 libraries before packaging (requires glibc $required)." >&2; exit 65
    fi
done
output=$(realpath -m -- "$1")
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
chmod 755 "$temporary"
payload=$temporary/opt/sapiens4-headless
mkdir -p "$payload/.build/bin" "$payload/.build/domain" "$payload/.build/web" "$payload/corpora" \
    "$payload/environments/linux" "$payload/submodules/libs4/node/bin" \
    "$payload/submodules/libs4/node_modules" "$payload/submodules/libs4/.cache/playwright" \
    "$temporary/DEBIAN" "$temporary/usr/bin"
install -m 755 "$build/bin/sapiens4" "$payload/.build/bin/"
install -m 755 "$build/domain/sapiens-domain" "$payload/.build/domain/"
install -m 755 "$node" "$payload/submodules/libs4/node/bin/"
strip "$payload/.build/bin/sapiens4" "$payload/.build/domain/sapiens-domain"
install -m 644 "$(dirname "$node")/../LICENSE" "$payload/submodules/libs4/node/"
for asset in app.js guest.js sw.js; do install -m 644 "$root/.build/web/$asset" "$payload/.build/web/"; done
cp -R "$root/app" "$root/license" "$payload/"
cp -R "$root/corpora/prompts" "$payload/corpora/"
for file in Bridge.cjs Browser.cjs README.md NATIVE.md; do install -m 644 "$root/environments/linux/$file" "$payload/environments/linux/"; done
for file in start.sh headless.sh virtual.sh; do install -m 755 "$root/environments/linux/$file" "$payload/environments/linux/"; done
cp -R "$root/submodules/libs4/web" "$root/submodules/libs4/license" "$payload/submodules/libs4/"
cp -R "$root/submodules/libs4/node_modules/playwright" "$root/submodules/libs4/node_modules/playwright-core" "$payload/submodules/libs4/node_modules/"
install -m 644 "$root/submodules/libs4/package.json" "$root/submodules/libs4/package-lock.json" "$payload/submodules/libs4/"
PLAYWRIGHT_BROWSERS_PATH="$root/submodules/libs4/.cache/playwright" node - "$root" "$payload" <<'JS'
const fs = require('node:fs'), path = require('node:path');
const [root, payload] = process.argv.slice(2);
const directory = path.join(root, 'submodules/libs4/.cache/playwright');
const {browsers} = require(path.join(root, 'submodules/libs4/node_modules/playwright-core/browsers.json'));
for (const browser of browsers.filter(item => ['chromium-headless-shell', 'chromium', 'firefox', 'ffmpeg'].includes(item.name))) {
  const name = browser.name.replaceAll('-', '_') + '-' + browser.revision;
  fs.cpSync(path.join(directory, name), path.join(payload, 'submodules/libs4/.cache/playwright', name), {recursive: true});
}
JS
cat > "$temporary/usr/bin/sapiens4-headless" <<'EOF'
#!/bin/sh
exec /opt/sapiens4-headless/environments/linux/start.sh "$@"
EOF
chmod 755 "$temporary/usr/bin/sapiens4-headless"
cat > "$temporary/DEBIAN/control" <<'EOF'
Package: sapiens4-headless
Version: 0.2.0~linux-dev2
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Sapiens4 <license@sapiens4.ai>
Conflicts: liboss4-salsa-asound2
Depends: libc6 (>= 2.35), libgmp10, libffi8, libnuma1, zlib1g, ca-certificates, fonts-liberation, fonts-dejavu-core, libasound2t64 (>= 1.2.11) | libasound2 (>= 1.2.6), libgtk-3-0 | libgtk-3-0t64, libnss3, libnspr4, libgbm1, libdbus-glib-1-2, libx11-xcb1, libxcomposite1, libxdamage1, libxfixes3, libxrandr2, libxkbcommon0, libxcursor1, xvfb, xauth, dbus-x11, openbox, x11-utils
Description: Sapiens4 headless Ubuntu adapter development preview
 Linux browser command translation with pinned Node and Playwright browsers.
 Supports software rendering and an optional isolated Xvfb desktop.
 No kernel, networking, desktop extension or autostart changes are made.
 Enterprise production qualification remains pending.
EOF
mkdir -p "$(dirname -- "$output")"
dpkg-deb -Zzstd --root-owner-group --build "$temporary" "$output"
(cd "$(dirname -- "$output")" && sha256sum -- "$(basename -- "$output")") > "$output.sha256"

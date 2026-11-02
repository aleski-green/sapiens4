#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-$root/submodules/libs4/.cache/playwright}
node=$root/submodules/libs4/node/bin/node
if [ ! -x "$node" ]; then node=node; fi
exec "$node" "$root/environments/linux/Bridge.cjs" "$@"

#!/bin/sh
set -eu
cd "$(dirname "$0")"
git submodule update --init --recursive
if [ "$(uname -s)" = Darwin ]; then
  swift build --package-path blindly4 -c release
else
  echo "Blindly4 computer tasks require macOS. Chat is available on this platform."
fi
exec python3 -m sapiens "$@"

#!/bin/sh
set -eu
cd "$(dirname "$0")"
git submodule update --init --recursive
if [ "$(uname -s)" = Darwin ]; then
  ./blindly4/macos/build.sh
else
  echo "Blindly4 computer tasks require macOS. Chat is available on this platform."
fi
python3 web/shell/build.py
exec python3 -m sapiens "$@"

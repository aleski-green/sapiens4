#!/bin/sh
set -eu
cd "$(dirname "$0")"
git submodule update --init --recursive
if [ "$(uname -s)" = Darwin ]; then
  ./blindly4/macos/build.sh
else
  echo "Blindly4 computer tasks require macOS. Chat is available on this platform."
fi
runghc Build.hs
exec .build/bin/sapiens4 "$@"

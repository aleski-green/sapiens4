#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ "$#" -ne 2 ]; then echo 'Usage: qualify.sh headless|xorg|wayland|visible-xorg|visible-wayland NEW_REPORT_DIRECTORY' >&2; exit 64; fi
mode=$1
case "$mode" in headless|xorg|wayland|visible-xorg|visible-wayland) ;; *) echo 'Unknown qualification mode' >&2; exit 64 ;; esac
report=$(realpath -m -- "$2")
mkdir -p -- "$(dirname -- "$report")"
if ! mkdir -- "$report"; then echo 'Choose a new report directory to preserve earlier evidence' >&2; exit 64; fi
cd "$root"
python3 - "$mode" > "$report/environment.json" <<'PY'
import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=True, timeout=15)
    return result.stdout.strip()

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()

artifacts = [Path('.build/bin/sapiens-linux'), Path('submodules/blindly4/.build/debug/blindly4')]
print(json.dumps({
    'time': datetime.now(timezone.utc).isoformat(),
    'mode': sys.argv[1], 'kernel': platform.release(), 'architecture': platform.machine(),
    'os': Path('/etc/os-release').read_text(), 'commit': command('git', 'rev-parse', 'HEAD'),
    'worktree': command('git', 'status', '--short'),
    'submodules': command('git', 'submodule', 'status', '--recursive'),
    'ruby': command('ruby', '--version'), 'node': command('node', '--version'),
    'browser_overrides': {key: os.environ.get(key) for key in (
        'SAPIENS_TEST_FIREFOX_EXECUTABLE', 'SAPIENS_TEST_FIREFOX_CHANNEL',
        'SAPIENS_TEST_CHROMIUM_EXECUTABLE', 'SAPIENS_TEST_CHROMIUM_CHANNEL')},
    'sha256': {str(path): digest(path) for path in artifacts if path.is_file()},
}, indent=2))
PY
unset SAPIENS_TEST_XORG SAPIENS_TEST_VIRTUAL_DISPLAY SAPIENS_TEST_HEADLESS SAPIENS_TEST_VISIBLE
export SAPIENS_TEST_GNOME_LOGS=$report/session
if [ "$mode" = headless ]; then
    export SAPIENS_TEST_HEADLESS_BROWSERS=1
    set -- ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_bridge_spec.rb spec/linux_external_browser_spec.rb spec/linux_launch_spec.rb
else
    case "$mode" in
        xorg) export SAPIENS_TEST_XORG=1 ;;
        wayland) export SAPIENS_TEST_HEADLESS=1 ;;
        visible-xorg) export SAPIENS_TEST_XORG=1 SAPIENS_TEST_VISIBLE=1 ;;
        visible-wayland) export SAPIENS_TEST_VISIBLE=1 ;;
    esac
    export SAPIENS_TEST_GNOME_FOREGROUND=1 SAPIENS_TEST_LINUX_AUTOMATION=1 SAPIENS_TEST_LINUX_EXTERNAL_DESKTOP=1
    set -- spec/support/gnome-session.sh ruby submodules/libs4/ruby/bundle.rb exec rspec spec/linux_commands_spec.rb spec/linux_desktop_spec.rb spec/linux_browser_spec.rb spec/linux_native_browser_spec.rb spec/linux_foreground_spec.rb spec/linux_automation_spec.rb
    if [ "$mode" = xorg ] || [ "$mode" = visible-xorg ]; then
        set -- "$@" spec/app_remote_spec.rb spec/ui_state_spec.rb spec/workspace_accessibility_spec.rb \
            spec/relay_browser_spec.rb spec/chat_scroll_spec.rb spec/linux_settings_spec.rb \
            spec/groups_browser_spec.rb spec/corpora_browser_spec.rb spec/idle_browser_spec.rb spec/windows_package_spec.rb
    fi
fi
status=0
"$@" --format documentation --format json --out "$report/results.json" > "$report/run.log" 2>&1 || status=$?
printf 'Qualification exit status: %s; evidence: %s\n' "$status" "$report"
exit "$status"

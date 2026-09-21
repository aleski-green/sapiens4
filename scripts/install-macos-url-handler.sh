#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This installer requires macOS." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_path="$HOME/Applications/Sapi4Handler.app"
handler_version="$(cat "$script_dir/Sapi4Handler.applescript" "$0" | /usr/bin/shasum -a 256 | cut -d ' ' -f 1)"
if [[ -e "$app_path" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != ai.sapiens4.url-handler ]]; then
    echo "Refusing to replace an unrelated app at $app_path" >&2
    exit 1
  fi
  existing_version="$(/usr/libexec/PlistBuddy -c 'Print :Sapi4HandlerVersion' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_version" == "$handler_version" ]]; then
    exit 0
  fi
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/sapi4-handler.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
build_app="$build_dir/Sapi4Handler.app"
/usr/bin/osacompile -o "$build_app" "$script_dir/Sapi4Handler.applescript"
plist="$build_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ai.sapiens4.url-handler' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Sapi4' "$plist"
/usr/libexec/PlistBuddy -c "Add :Sapi4HandlerVersion string $handler_version" "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes array' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0 dict' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLName string Sapi4 Corpora' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string sapi4' "$plist"
/usr/bin/plutil -lint "$plist"
/usr/bin/codesign --force --sign - "$build_app"
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$build_app" "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
echo "Installed $app_path"
echo "Open sapi4://corpora in your browser, or run: open 'sapi4://corpora'"

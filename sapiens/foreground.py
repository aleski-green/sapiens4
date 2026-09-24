"""Return to the CORPORA host after a bounded computer attempt."""
from pathlib import Path
import subprocess
import sys


HOST_APPS = {'com.sapiens4.desktop', 'com.openai.codex', 'com.google.Chrome', 'com.apple.Safari', 'com.microsoft.edgemac', 'org.mozilla.firefox'}


def front_bundle():
    # AppKit observation requires no browser scripting/Automation permission.
    result = subprocess.run(['osascript', '-l', 'JavaScript', '-e',
        "ObjC.import('AppKit'); $.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.js"],
        capture_output=True, text=True, timeout=5)
    return result.stdout.strip() if result.returncode == 0 else None


class ForegroundReturn:
    def __init__(self, workdir):
        self.root = Path(workdir)
        self.marker = self.root / '.computer-used'
        self.before = self.marker.stat().st_mtime_ns if self.marker.exists() else None
        self.bundle = None
        self.enabled = sys.platform == 'darwin' and (self.root/'host-control.json').exists()
        if self.enabled:
            try:
                bundle = front_bundle()
                self.bundle = bundle if bundle in HOST_APPS else None
            except (OSError, subprocess.TimeoutExpired):
                pass

    def restore(self):
        if not self.enabled or not self.bundle or not self.marker.exists() or self.marker.stat().st_mtime_ns == self.before:
            return None
        try:
            # Return to the captured host without opening a workspace URL/tab.
            result = subprocess.run(['/usr/bin/open', '-b', self.bundle], capture_output=True, text=True, timeout=5)
            if result.returncode:
                return 'Could not bring CORPORA back to the foreground.'
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
            return 'Could not bring CORPORA back to the foreground.'
        return None

"""Per-user discovery for the macOS sapi4://corpora launcher."""
import logging
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

from .paths import ROOT


class WorkspaceLink:
    def __init__(self, path=None):
        self.path = path if path is not None else (
            Path.home() / "Library/Application Support/Sapiens4/workspace.plist")
        self.token = uuid.uuid4().hex

    def publish(self, port, pid=None):
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("Expected a bound TCP port")
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        raw = plistlib.dumps({"port": port, "pid": os.getpid() if pid is None else pid,
                              "owner": self.token})
        fd, temporary = tempfile.mkstemp(dir=self.path.parent, prefix=".workspace-")
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(raw)
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def close(self):
        try:
            # An older server must not remove a newer server's registration.
            if plistlib.loads(self.path.read_bytes()).get("owner") == self.token:
                self.path.unlink()
        except FileNotFoundError:
            pass


def register_workspace_link(port):
    if sys.platform != "darwin":
        return None
    registration = WorkspaceLink()
    try:
        subprocess.run(["/bin/bash", str(ROOT / "scripts/install-macos-url-handler.sh")],
                       check=True, capture_output=True, text=True, timeout=30)
        registration.publish(port)
    except (OSError, subprocess.SubprocessError) as error:
        logging.warning("Could not register sapi4://corpora: %s", error)
        return None
    return registration

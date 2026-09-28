"""Codex selection shared by the runtime and installation checks."""
from functools import lru_cache
import os
import json
import re
import shutil
import subprocess
import sys


MIN_CODEX_VERSION = (0, 156, 1)
DEFAULT_MODEL = 'gpt-6-sol'
DEFAULT_REASONING = 'high'


def model_defaults():
    return (os.environ.get('SAPIENS_CODEX_MODEL') or DEFAULT_MODEL,
            os.environ.get('SAPIENS_CODEX_REASONING_EFFORT') or DEFAULT_REASONING)


def cli_version(binary):
    result = subprocess.run([binary, '--version'], capture_output=True, text=True,
                            timeout=10, check=True)
    match = re.search(r'codex-cli\s+(\d+)\.(\d+)\.(\d+)', result.stdout)
    if not match:
        raise RuntimeError('Could not read the Codex CLI version: ' + result.stdout.strip())
    return tuple(map(int, match.groups()))


@lru_cache(maxsize=1)
def codex_binary():
    """Choose the newest installed CLI; an explicit app-local override wins."""
    override = os.environ.get('SAPIENS_CODEX_BINARY')
    if override:
        return shutil.which(override)
    candidates = [shutil.which('codex')]
    if sys.platform == 'darwin':
        candidates += [f'/Applications/{app}.app/Contents/Resources/codex'
                       for app in ('Codex', 'ChatGPT')]
    versions = []
    for path in dict.fromkeys(p for p in candidates if p and os.access(p, os.X_OK)):
        try:
            versions.append((cli_version(path), path))
        except (OSError, RuntimeError, subprocess.SubprocessError):
            continue
    return max(versions, default=((), None))[1]


def execution_settings(root):
    path = root / 'run-settings.json'
    if not path.exists():
        path = root / 'execution.json'  # Read legacy mode/timeout without restoring budgets.
    saved = json.loads(path.read_text()) if path.exists() else {}
    mode = 'deep' if saved.get('mode') == 'deep' else 'normal'
    ceiling = 1200 if mode == 'deep' else 300
    timeout = saved.get('timeout_seconds', ceiling)
    return dict(mode=mode, timeout_seconds=min(ceiling, max(15, timeout)) if type(timeout) is int else ceiling)

"""Codex selection shared by the runtime and installation checks."""
from functools import lru_cache
from pathlib import Path
import os
import json
import re
import shutil
import subprocess
import sys

from sapiens.runtime.contracts import RUN_TIMEOUT_SECONDS


MIN_CODEX_VERSION = (0, 156, 1)
DEFAULT_MODEL = 'gpt-6-sol'
DEFAULT_REASONING = 'high'


def model_defaults():
    return (os.environ.get('SAPIENS_CODEX_MODEL') or DEFAULT_MODEL,
            os.environ.get('SAPIENS_CODEX_REASONING_EFFORT') or DEFAULT_REASONING)


def cli_version(binary):
    result = subprocess.run([binary, '--version'], capture_output=True, text=True,
                            encoding='utf-8', timeout=10, check=True,
                            **({'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}))
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
    elif sys.platform == 'win32':
        local = Path(os.environ.get('LOCALAPPDATA', Path.home() / 'AppData/Local'))
        roaming = Path(os.environ.get('APPDATA', Path.home() / 'AppData/Roaming'))
        candidates += [str(p) for p in (local / 'OpenAI/Codex/bin').glob('*/codex.exe')]
        candidates += [str(p) for p in (roaming / 'npm/node_modules/@openai').glob('codex*/vendor/*/codex/codex.exe')]
        candidates += [str(p) for p in (roaming / 'npm/node_modules/@openai/codex/node_modules/@openai').glob('codex*/vendor/*/codex/codex.exe')]
        # Prefer the native program, avoiding npm's cmd.exe quoting layer.
        candidates = [p for p in candidates if p and Path(p).suffix.lower() == '.exe']
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
        path = root / 'execution.json'  # Preserve legacy reasoning mode; saved timeouts no longer apply.
    saved = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
    mode = 'deep' if saved.get('mode') == 'deep' else 'normal'
    return dict(mode=mode, timeout_seconds=RUN_TIMEOUT_SECONDS)

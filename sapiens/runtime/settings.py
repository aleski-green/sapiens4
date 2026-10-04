"""Harness selection shared by runtime and installation checks."""
from functools import lru_cache
import os
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

from sapiens.runtime.contracts import RUN_TIMEOUT_SECONDS


MIN_CODEX_VERSION = (0, 156, 1)
DEFAULT_MODEL = 'gpt-6-sol'
DEFAULT_REASONING = 'high'


def harness_name():
    name = os.environ.get('SAPIENS_HARNESS', 'kimi').lower()
    if name not in {'kimi', 'codex'}:
        raise ValueError('SAPIENS_HARNESS must be kimi or codex')
    return name


def model_defaults(provider=None):
    provider = provider or harness_name()
    prefix = 'SAPIENS_' + provider.upper() + '_'
    return (os.environ.get('SAPIENS_HARNESS_MODEL') or os.environ.get(prefix + 'MODEL')
            or ('kimi-for-coding' if provider == 'kimi' else DEFAULT_MODEL),
            os.environ.get('SAPIENS_HARNESS_REASONING_EFFORT')
            or os.environ.get(prefix + 'REASONING_EFFORT') or DEFAULT_REASONING)


def harness_binary(provider=None):
    provider = provider or harness_name()
    override = os.environ.get('SAPIENS_HARNESS_BINARY')
    if override:
        return shutil.which(override)
    if provider == 'codex':
        return codex_binary()
    override = os.environ.get('SAPIENS_KIMI_BINARY')
    if override:
        return shutil.which(override)
    return shutil.which('kimi') or shutil.which(str(Path.home() / '.kimi-code/bin/kimi'))


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
        path = root / 'execution.json'  # Preserve legacy reasoning mode; saved timeouts no longer apply.
    saved = json.loads(path.read_text()) if path.exists() else {}
    mode = 'deep' if saved.get('mode') == 'deep' else 'normal'
    return dict(mode=mode, timeout_seconds=RUN_TIMEOUT_SECONDS)

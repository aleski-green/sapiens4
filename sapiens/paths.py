"""Repository locations, independent of runtime initialization."""
from pathlib import Path
import os
import shlex
import sys


ROOT = Path(__file__).resolve().parent.parent


def blindly_binary():
    override = os.environ.get('SAPIENS_BLINDLY_BINARY')
    if override:
        return Path(override).expanduser().resolve()
    relative = 'blindly4/.build/windows/blindly4.exe' if sys.platform == 'win32' else 'blindly4/.build/release/blindly4'
    return ROOT / relative


def shell_command(parts):
    """Commands embedded in agent prompts target PowerShell on Windows."""
    if sys.platform == 'win32':
        return '& ' + ' '.join("'" + str(p).replace("'", "''") + "'" for p in parts)
    return ' '.join(shlex.quote(str(p)) for p in parts)

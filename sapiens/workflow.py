"""Forward only this execution's explicitly acquired Blindly lease."""
import json
import os
import tempfile
from pathlib import Path
import subprocess


def owned(workdir):
    root = Path(workdir)
    try:
        clock = json.loads((root / 'execution-clock.json').read_text())
        lease = json.loads((root / 'workflow-lease.json').read_text())
        if (clock.get('active') and lease['deadline'] == clock['deadline']
                and isinstance(lease.get('token'), str) and lease['token']):
            return lease
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def invoke(binary, args, workdir):
    root = Path(workdir)
    lease = owned(root)
    command = list(args)
    if lease and '--lease' not in command:
        command += ['--lease', lease['token']]
    result = subprocess.run([str(binary), *command], capture_output=True, text=True, timeout=30)
    if args == ['workflow', 'acquire'] and result.returncode == 0:
        try:
            clock = json.loads((root / 'execution-clock.json').read_text())
            token = json.loads(result.stdout)['token']
            if clock.get('active'):
                # No SDK import: this module also runs from the computer.py script.
                path = root / 'workflow-lease.json'
                with tempfile.NamedTemporaryFile(mode='w', dir=root, delete=False) as stream:
                    temporary = Path(stream.name)
                    json.dump(dict(deadline=clock['deadline'], token=token), stream)
                try:
                    os.replace(temporary, path)
                finally:
                    temporary.unlink(missing_ok=True)
        except (OSError, ValueError, KeyError, TypeError):
            pass
    if args[:2] == ['workflow', 'release'] and result.returncode == 0 and lease:
        (root / 'workflow-lease.json').unlink(missing_ok=True)
    return result


def release(binary, workdir):
    lease = owned(workdir)
    if not lease:
        return
    try:
        result = subprocess.run([str(binary), 'workflow', 'release', '--lease', lease['token']],
                                capture_output=True, text=True, timeout=5)
        if result.returncode:
            return 'The owned Blindly workflow lease could not be released; it may remain until expiry.'
        (Path(workdir) / 'workflow-lease.json').unlink(missing_ok=True)
    except (OSError, subprocess.TimeoutExpired):
        return 'The owned Blindly workflow lease could not be released; it may remain until expiry.'

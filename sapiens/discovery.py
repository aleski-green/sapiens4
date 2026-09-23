"""Per-execution bounds on live UI discovery; cached pagination remains available."""
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
import fcntl
import json

READS = {'apps', 'focused', 'tree', 'find', 'inspect', 'schema', 'read'}


@contextmanager
def admission(directory, command):
    root = Path(directory)
    clock_path = root / 'execution-clock.json'
    if command not in READS or not clock_path.exists():
        yield None
        return
    # Serializes admission from parallel tool calls without holding the lock during UI work.
    with (root / 'discovery.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        clock = json.loads(clock_path.read_text())
        path = root / 'discovery.json'
        state = json.loads(path.read_text()) if path.exists() else {}
        if state.get('deadline') != clock['deadline']:
            state = dict(deadline=clock['deadline'], calls=0)
        cutoff = clock.get('discovery_until', clock['finish_by'])
        if not clock.get('active') or datetime.now(timezone.utc) >= datetime.fromisoformat(cutoff):
            state['blocked'] = 'The live UI discovery time allowance is exhausted.'
        elif state['calls'] >= 12:
            state['blocked'] = 'The limit of 12 live UI discovery calls is exhausted.'
        if not state.get('blocked'):
            state['calls'] += 1
        path.write_text(json.dumps(state))
        blocked = state.get('blocked')
    yield blocked


def blocker(directory, deadline):
    try:
        state = json.loads((Path(directory) / 'discovery.json').read_text())
        return state.get('blocked') if state.get('deadline') == deadline else None
    except (OSError, ValueError):
        return None

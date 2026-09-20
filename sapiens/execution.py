"""Small execution clock shared with the agent's host-control command."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import json


def start(timeout, max_tools):
    now = datetime.now(timezone.utc)
    reserve = min(30, timeout / 4)
    return dict(active=True, deadline=(now + timedelta(seconds=timeout)).isoformat(),
                finish_by=(now + timedelta(seconds=timeout-reserve)).isoformat(),
                max_tools=max_tools, tools_used=0)


def read(workdir):
    try:
        value = json.loads((Path(workdir) / 'execution-clock.json').read_text())
        now = datetime.now(timezone.utc)
        remaining = max(0, (datetime.fromisoformat(value['deadline'])-now).total_seconds())
        finishing = now >= datetime.fromisoformat(value['finish_by'])
        return {**value, 'seconds_remaining': round(remaining, 1),
                'tools_remaining': max(0, value['max_tools']-value['tools_used']),
                'phase': 'stopped' if not value['active'] or not remaining else
                         'save_and_finish' if finishing else 'investigate'}
    except (OSError, ValueError, KeyError, TypeError):
        return None

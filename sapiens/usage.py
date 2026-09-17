"""Durable per-attempt usage, projected into SQLite for rolling UI reports.

Budget units are a local policy, NOT dollars or subscription quota: uncached
input + output + ceil(cached input / 10). Raw provider counters stay intact.
"""
from datetime import datetime, timedelta, timezone
import json
import math
from uuid import uuid4
from agentpy.storage import atomic_bytes

DEFAULTS = dict(weekly_limit=1_000_000, call_allowance=100_000,
                max_tools=16, timeout_seconds=120, output_tokens=1200)


def counters(usage):
    if not usage or 'input_tokens' not in usage or 'output_tokens' not in usage:
        return None
    raw = max(0, int(usage['input_tokens']))
    cached = min(raw, max(0, int(usage.get('cached_input_tokens', 0))))
    output = max(0, int(usage['output_tokens']))
    return dict(input=raw, cached=cached, uncached=raw-cached, output=output,
                total=raw+output, units=raw-cached+output+math.ceil(cached/10))


def settings(agent):
    path = agent.root / 'execution.json'
    return {**DEFAULTS, **(json.loads(path.read_text()) if path.exists() else {})}


def validate(data):
    from .service import APIError
    ranges = dict(weekly_limit=(1000, 100_000_000), call_allowance=(1000, 1_000_000),
                  max_tools=(1, 100), timeout_seconds=(15, 600), output_tokens=(200, 8000))
    if not isinstance(data, dict) or set(data) != set(ranges):
        raise APIError(400, 'Provide all execution limit fields')
    for key, (lo, hi) in ranges.items():
        if type(data[key]) is not int or not lo <= data[key] <= hi:
            raise APIError(400, f'{key} must be an integer from {lo} to {hi}')
    if data['call_allowance'] * 3 > data['weekly_limit']:
        raise APIError(400, 'Weekly allowance must cover three calls for consolidation')
    return data


def save_record(agent, row):
    directory = agent.root / 'usage'
    directory.mkdir(exist_ok=True)
    atomic_bytes(directory / (row['id'] + '.json'), json.dumps(row).encode())


def backfill(agent):
    """One-time import. Missing older attempts stay unknown; never invent usage."""
    marker = agent.root / 'usage-imported.json'
    if marker.exists():
        return
    state = agent.state
    jobs = {j['id']: j for j in state['jobs']}
    end = {e['job']: e['time'] for e in state['events']
           if e.get('job') and e['kind'] in {'done', 'failed', 'conflict', 'interrupted'}}
    for path in (agent.corpora.root / 'archive' / agent.agid / 'runs').glob('*.json'):
        job = jobs.get(path.stem, {})
        for i, log in enumerate(json.loads(path.read_text()).get('logs', [])):
            identity = f'legacy-{path.stem}-{i}'
            if (agent.root / 'usage' / (identity + '.json')).exists():
                continue
            save_record(agent, dict(id=identity, job=path.stem, flow=job.get('flow', 'unknown'),
                role=log.get('role'), session=log.get('session'), usage=log.get('usage'),
                time=end.get(path.stem) or datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(),
                status=job.get('status', 'unknown'), historical=True, approximate_time=True,
                prompt_chars=len(log.get('prompt', '')), tools=None, output_chars=None))
    atomic_bytes(marker, b'{"version":1}')


class Usage:
    def __init__(self, store):
        self.store = store
        self.seen = set()
        with store.connect() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS usage_calls (
                id TEXT PRIMARY KEY, agent TEXT NOT NULL, time TEXT NOT NULL, value TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS usage_time ON usage_calls(agent,time);''')

    def sync(self, agent):
        jobs = {j['id']: j for j in agent.state['jobs']}
        for path in (agent.root / 'usage').glob('*.json'):
            key = (agent.agid, path.name, path.stat().st_mtime_ns)
            if key in self.seen:
                continue
            row = json.loads(path.read_text())
            job = jobs.get(row.get('job'))
            if row.get('status') == 'running' and job and job['status'] not in {'running','queued'}:
                # A killed process cannot report final counters. Keep it unknown
                # and expose the recovered state instead of a perpetual spinner.
                row['status'] = job['status']
                save_record(agent, row)
            with self.store.connect() as db:
                db.execute('INSERT INTO usage_calls VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET time=excluded.time,value=excluded.value',
                           (row['id'], agent.agid, row['time'], json.dumps(row)))
            self.seen.add(key)

    def report(self, agent, instant=None):
        self.sync(agent)
        instant = instant or datetime.now(timezone.utc)
        with self.store.connect() as db:
            rows = [json.loads(r[0]) for r in db.execute('SELECT value FROM usage_calls WHERE agent=? AND time>=? AND time<=? ORDER BY time DESC',
                (agent.agid, (instant-timedelta(days=7)).isoformat(), instant.isoformat()))]
        windows = {}
        for label, seconds in [('hour', 3600), ('day', 86400), ('week', 604800)]:
            calls = [r for r in rows if datetime.fromisoformat(r['time']) >= instant-timedelta(seconds=seconds)]
            totals = dict(input=0, cached=0, uncached=0, output=0, total=0, units=0)
            unknown = 0
            for row in calls:
                count = counters(row.get('usage'))
                if count is None:
                    unknown += 1
                else:
                    for key in totals:
                        totals[key] += count[key]
            windows[label] = {**totals, 'calls': len(calls), 'unknown': unknown,
                              'historical': sum(bool(r.get('historical')) for r in calls)}
        return dict(windows=windows, budget=agent.budget_status(instant), settings=settings(agent),
                    recent=[{k: v for k, v in r.items() if k not in {'usage','observations'}} | {'tokens': counters(r.get('usage'))}
                            for r in rows[:20]], as_of=instant.isoformat())

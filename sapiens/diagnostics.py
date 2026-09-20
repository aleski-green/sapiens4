"""Read-only, bounded budget and execution diagnostics from saved host evidence."""
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json

from .usage import counters, settings
from .validation import APIError


def category(job):
    error = job.get('error') or job.get('warning') or ''
    if 'TimeoutError' in error or 'time limit' in error.lower():
        return 'timeout'
    if 'tool-step limit' in error.lower() or 'tool limit' in error.lower():
        return 'tool_limit'
    if job['status'] == 'budget_blocked' or 'allowance' in error.lower():
        return 'budget_allowance'
    if job['status'] == 'interrupted':
        return 'interrupted'
    return 'execution_error' if error or job['status'] in {'failed', 'conflict'} else 'unknown_usage'


def report(service, agents, offset=0, limit=10):
    if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 20:
        raise APIError(400, 'offset must be nonnegative; limit must be 1–20')
    now = datetime.now(timezone.utc)
    summaries, issues = [], []
    names = {a['id']: a['name'] for a in service.store.agents()}
    for agent in agents:
        service.usage.sync(agent)
        with service.store.connect() as db:
            rows = [json.loads(r[0]) for r in db.execute(
                'SELECT value FROM usage_calls WHERE agent=?', (agent.agid,))]
        unknown = defaultdict(list)
        for row in rows:
            if row.get('status') not in {'running', 'queued'} and counters(row.get('usage')) is None:
                unknown[row.get('job')].append(row)
        budget = agent.budget_status(now)
        policy = settings(agent)
        required = {flow: sum(isinstance(step, str) for step in agent.config.flows[flow].steps)*policy['call_allowance']
                    for flow in ('chat', 'learning')}
        jobs = agent.state['jobs']
        summaries.append(dict(id=agent.agid, name=names[agent.agid], budget=budget,
            admission={flow: dict(required_units=units, shortfall_units=max(0, units-budget['remaining']))
                       for flow, units in required.items()},
            limits={k: policy[k] for k in ('timeout_seconds', 'max_tools', 'call_allowance')},
            unknown_usage_attempts=sum(map(len, unknown.values())),
            fallback_units_retained_history=sum(r.get('budget_units', 0) for group in unknown.values() for r in group)))
        for job in jobs:
            attempts = unknown.pop(job['id'], [])
            if not (job.get('error') or job.get('warning') or attempts or
                    job['status'] in {'failed', 'interrupted', 'conflict', 'budget_blocked'}):
                continue
            issues.append(dict(agent=agent.agid, job=job['id'], flow=job['flow'], status=job['status'],
                category=category(job), error=(job.get('error') or job.get('warning') or '').split('\n')[0][:280],
                unknown_usage_attempts=len(attempts), fallback_units=sum(r.get('budget_units', 0) for r in attempts)))
        for job, attempts in unknown.items():
            issues.append(dict(agent=agent.agid, job=job, status='archived', category='unknown_usage',
                unknown_usage_attempts=len(attempts), fallback_units=sum(r.get('budget_units', 0) for r in attempts)))
    return dict(as_of=now.isoformat(), scope='Current budgets; issues and unknown usage from retained history.',
        units='Budget units are local allowances, not measured tokens or provider quota. Unknown usage stays unknown.',
        agents=summaries, issue_counts=dict(Counter(i['category'] for i in issues)),
        issues=issues[offset:offset+limit], total_issues=len(issues),
        next_offset=offset+limit if offset+limit < len(issues) else None)

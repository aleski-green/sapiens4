"""Bounded, durable director briefings for new actionable team problems."""
from datetime import datetime, timedelta
from uuid import uuid4
import hashlib
import json


def enqueue_review(service, agent, team, instant):
    members = {member['id']: member for member in team}

    def subordinate(member):
        seen = {member['id']}
        parent = member.get('manager')
        while parent and parent not in seen:
            if parent == agent.agid:
                return True
            seen.add(parent)
            parent = members.get(parent, {}).get('manager')
        return False

    issues = {}
    for member in team:
        if member['id'] == agent.agid or not subordinate(member):
            continue
        for job in service._agent(member['id']).state['jobs']:
            if job['flow'] != 'team_review' and job['status'] in {'failed', 'interrupted', 'conflict', 'budget_blocked'}:
                issues['run:' + job['id']] = dict(agent=member['name'], run=job['id'],
                    status=job['status'], task=job['task'][:300], error=(job.get('error') or '')[:500])
        for job in member['recurring_jobs']:
            if job['enabled'] and job['health']['status'] in {'blocked', 'overdue', 'partial', 'budget_blocked', 'review_needed'}:
                issues['recurring:' + job['id']] = dict(agent=member['name'], job=job['id'],
                    title=job['title'], status=job['health']['status'], reason=(job['health']['reason'] or '')[:500])

    allowed = agent.can_admit('team_review', instant) and not service.work.blocking(agent)
    # Enqueue and acknowledge in the same SDK transaction. A crash cannot lose
    # a pending review or enqueue the same problem twice. Resolved issues leave
    # this set, so a later recurrence can be reviewed again.
    with agent.store.transaction() as state:
        saved = state.setdefault('team_reviews', dict(issues={}, attempts=[]))
        current = {}
        for key, value in issues.items():
            digest = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
            previous = saved['issues'].get(key, {})
            current[key] = previous if previous.get('digest') == digest else dict(digest=digest, reviewed=False)
        saved['issues'] = current
        saved['attempts'] = [time for time in saved['attempts']
                             if datetime.fromisoformat(time) > instant - timedelta(days=1)]
        pending = [key for key in current if not current[key]['reviewed']][:8]
        if not pending or not allowed or len(saved['attempts']) >= 2:
            return
        agent._enqueue(state, 'team_review', json.dumps([issues[key] for key in pending], ensure_ascii=False),
                       key='team-review:' + uuid4().hex)
        for key in pending:
            current[key]['reviewed'] = True
        saved['attempts'].append(instant.isoformat())

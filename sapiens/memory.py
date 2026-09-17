"""Compare learning inputs, excluding bookkeeping and learning's own output."""
from copy import deepcopy
import hashlib
import json


def fingerprint(blocks):
    manifests = blocks.get('manifests', {})
    facts = json.loads(manifests.get('host-facts', '{}'))
    schedule = facts.get('schedule', {})
    # Timer ticks, budgets, memory counts and selected browser tabs are not new
    # experience. Only keep durable facts that learning actually receives.
    stable = dict(
        identity=manifests.get('identity'),
        comments=manifests.get('task-comments', '[]'),
        schedule={k: schedule[k] for k in ('enabled', 'minutes', 'monitor_team') if k in schedule},
        team=[{k: member.get(k) for k in ('id', 'name', 'role', 'manager')}
              for member in facts.get('team', [])],
        recurring=[{k: row.get(k) for k in ('id', 'title', 'prompt', 'minutes', 'enabled', 'watch', 'checkpoint')}
                   for row in facts.get('recurring_jobs', [])],
        artifacts=facts.get('workspace', {}).get('artifacts', []),
        **{k: blocks.get(k, []) for k in ('chat', 'notes', 'tasks', 'goals')})
    return hashlib.sha256(json.dumps(stable, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def inputs(state, manifests):
    return dict(manifests=manifests, chat=state['chat'], notes=state['notes'],
                tasks=state['tasks'], goals=state['projects'])


def last_fingerprint(agent):
    run = next((j for j in reversed(agent.state['jobs'])
                if j['flow'] == 'learning' and j['status'] == 'done'), None)
    if not run:
        return None
    if run.get('memory_input_fingerprint'):
        return run['memory_input_fingerprint']
    # Older successful runs already archived their exact input. Recover it
    # without paying for a new model call or assuming today's state was learned.
    cache = getattr(agent, '_legacy_memory_fingerprints', {})
    if run['id'] not in cache:
        value = None
        try:
            prompt = agent.transcript(run['id'])[0]['prompt']
            start = prompt.index('{"manifests":')
            blocks, _ = json.JSONDecoder().raw_decode(prompt[start:])
            value = fingerprint(blocks)
        except (IndexError, KeyError, ValueError, FileNotFoundError):
            pass  # Unknown historical inputs: allow a fresh consolidation.
        cache[run['id']] = value
        agent._legacy_memory_fingerprints = cache
    return cache[run['id']]


def current_fingerprint(service, agent):
    manifests = deepcopy(agent.manifests)
    manifests['host-facts'] = json.dumps(service.orchestration.status(agent))
    manifests['task-comments'] = json.dumps([r for r in service.tasks.activity(agent)
        if r['kind'] == 'comment'][-20:], ensure_ascii=False)
    return fingerprint(inputs(agent.state, manifests))

"""Recurring job definitions and run references alongside SDK runtime state."""
from datetime import datetime, timedelta, timezone
import json
from uuid import uuid4

from agentpy.storage import atomic_bytes
from .orchestration import utcnow


class Work:
    def __init__(self, service):
        self.service = service

    def read(self, agent):
        path = agent.root / 'recurring.json'
        return json.loads(path.read_text()) if path.exists() else []

    def save(self, agent, definitions):
        atomic_bytes(agent.root / 'recurring.json', json.dumps(definitions).encode())

    def upsert(self, agent, data):
        from .service import APIError, text_field
        allowed = {'id', 'title', 'prompt', 'minutes', 'enabled'}
        if set(data) - allowed:
            raise APIError(400, 'Unknown recurring job field')
        definitions = self.read(agent)
        old = next((j for j in definitions if j['id'] == data.get('id')), None)
        if 'id' in data and old is None:
            raise APIError(404, 'Unknown recurring job')
        if old is None and len(definitions) >= 100:
            raise APIError(400, 'Maximum 100 recurring jobs per Sapi')
        row = {**(old or {}), **data}
        row['title'] = text_field(row, 'title', 120)
        row['prompt'] = text_field(row, 'prompt', 2000)
        if type(row.get('minutes')) is not int or not 1 <= row['minutes'] <= 10080:
            raise APIError(400, 'Interval must be 1–10080 minutes')
        if type(row.get('enabled', True)) is not bool:
            raise APIError(400, 'enabled must be boolean')
        row.setdefault('enabled', True)
        if old is None:
            row.update(id=uuid4().hex, created=utcnow().isoformat(), runs=[], last_run=None)
        if old is None or row['minutes'] != old['minutes'] or row['enabled'] != old['enabled']:
            row['next_run'] = (utcnow() + timedelta(minutes=row['minutes'])).isoformat() if row['enabled'] else None
        self.save(agent, [j for j in definitions if j['id'] != row['id']] + [row])
        return row

    def due(self, agent, instant):
        return next((j for j in sorted(self.read(agent), key=lambda j: j['next_run'] or '')
                     if j['enabled'] and j['next_run'] and datetime.fromisoformat(j['next_run']) <= instant), None)

    def admit(self, agent, definition, instant, manual=False):
        # The deadline is the idempotency key: restart between enqueue and save
        # finds the same SDK run instead of repeating the action.
        slot = 'manual-' + uuid4().hex if manual else definition['next_run']
        run = agent.submit('scheduled', definition['prompt'], key=f"recurring:{definition['id']}:{slot}")
        definitions = self.read(agent)
        row = next(j for j in definitions if j['id'] == definition['id'])
        row['last_run'] = instant.isoformat()
        if not manual:
            row['next_run'] = (instant + timedelta(minutes=row['minutes'])).isoformat()
        if not any(r['id'] == run for r in row['runs']):
            row['runs'].append(dict(id=run, title=row['title'], scheduled_for=slot, started=instant.isoformat()))
        self.save(agent, definitions)
        return run

    def run_now(self, agent, job_id):
        from .service import APIError
        definition = next((j for j in self.read(agent) if j['id'] == job_id), None)
        if definition is None:
            raise APIError(404, 'Unknown recurring job')
        self.require_idle(agent)
        run = self.admit(agent, definition, utcnow(), manual=True)
        self.service._sync(agent)
        self.service._queue.put(agent.agid)
        return run

    def require_idle(self, agent):
        from .service import APIError
        if self.service._stopping.is_set():
            raise APIError(503, 'Server is shutting down')
        unresolved = [j for j in agent.state['jobs'] if j['status'] not in {'done', 'cancelled'}]
        # An in-flight conversation may request one follow-up run. It executes
        # after that conversation through the same serialized queue.
        requesting_chat = len(unresolved) == 1 and unresolved[0]['status'] == 'running' and unresolved[0]['flow'] == 'chat'
        if agent.agid in self.service._background or (unresolved and not requesting_chat):
            raise APIError(409, 'Wait for current work, or retry/dismiss the run needing attention')

    def run_task(self, agent, task_id):
        from .service import APIError
        self.require_idle(agent)
        # SDK has no public run-task operation. Use its transaction/enqueue pair
        # so assigning the run and queuing it commit together, as tick() does.
        with agent.store.transaction() as state:
            task = next((t for t in state['tasks'] if t['id'] == task_id), None)
            if task is None:
                raise APIError(404, 'Unknown task')
            if task.get('job'):
                raise APIError(409, 'This task has already run; review its result')
            run = agent._enqueue(state, task['flow'], task['title'], task['id'])
            task['job'] = run
        self.service._sync(agent)
        self.service._queue.put(agent.agid)
        return run

    def finish_task(self, agent, task_id):
        from .service import APIError
        task = next((t for t in agent.state['tasks'] if t['id'] == task_id), None)
        if task is None:
            raise APIError(404, 'Unknown open task')
        if any(j['id'] == task.get('job') and j['status'] in {'queued', 'running'} for j in agent.state['jobs']):
            raise APIError(409, 'Wait for this task to finish running')
        agent.finish_task(task_id)

    def snapshot(self, agent, runs):
        definitions = self.read(agent)
        by_id = {j['id']: j for j in runs if j['agent'] == agent.agid}
        for definition in definitions:
            history = [{**by_id[r['id']], 'title': r['title'], 'scheduled_for': r['scheduled_for']}
                       for r in definition['runs'] if r['id'] in by_id]
            definition['runs'] = history
            definition['last_status'] = history[-1]['status'] if history else None
        completed = []
        directory = agent.corpora.root / 'archive' / agent.agid / 'tasks'
        for path in directory.glob('*.json'):
            task = json.loads(path.read_text())
            task['completed'] = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()
            completed.append(task)
        return dict(recurring=definitions, past_tasks=sorted(completed, key=lambda t: t['completed'], reverse=True))

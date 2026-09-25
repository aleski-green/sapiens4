"""Named one-off tasks and durable assignment notices in SDK runtime storage."""
from datetime import datetime
from uuid import uuid4
import json
import os
import re
import secrets
import string

from .clock import utcnow
from .sdk import atomic_bytes
from .validation import APIError, text_field


NAME = re.compile(r'[a-z][A-Za-z0-9_.:#+|()&$^\-]*')
TAGGED = re.compile(r'(task-[a-z][0-9]{4}):(.+)')
NAME_CHARS = r'A-Za-z0-9_:\-'


def handles(task):
    return list(dict.fromkeys([task.get('name', ''), task.get('tag', ''), *task.get('aliases', [])]))



class Tasks:
    def __init__(self, service):
        self.service = service

    def activity(self, agent):
        path = agent.root / 'task-activity.json'
        return json.loads(path.read_text()) if path.exists() else []

    def record(self, agent, task, kind, text, key=None, author=None, time=None):
        rows = self.activity(agent)
        if key and any(r['id'] == key for r in rows):
            return
        rows.append(dict(id=key or uuid4().hex, task=task['id'], name=task['name'],
            kind=kind, text=text, author=author or agent.agid, time=time or utcnow().isoformat(),
            agent=agent.agid, assigned_by=task.get('assigned_by', agent.agid)))
        atomic_bytes(agent.root / 'task-activity.json', json.dumps(rows, ensure_ascii=False).encode())

    def sync(self, agent, state, outputs):
        jobs = {j['id']: j for j in state['jobs']}
        events = state.get('events', [])
        for task in state['tasks']:
            if not task.get('name') or task.get('job') not in jobs:
                continue
            job = jobs[task['job']]
            labels = {'queued':'Queued', 'running':'Started', 'done':'Result ready for review',
                      'failed':'Failed', 'interrupted':'Interrupted', 'cancelled':'Dismissed',
                      'budget_blocked':'Budget blocked', 'conflict':'Needs review'}
            for event in events:
                if event.get('job') != job['id'] or event['kind'] not in {'started','done','failed','interrupted','cancelled','budget_blocked','conflict'}:
                    continue
                kind = 'running' if event['kind'] == 'started' else event['kind']
                detail = outputs.get(job['id'], '') if kind == 'done' else (job.get('error') or '') if kind in {'failed','interrupted','conflict'} else ''
                self.record(agent, task, kind, labels.get(kind,kind) + (':\n' + detail if detail else ''),
                            key=f"{job['id']}:{event['sequence']}", time=event['time'])
            if job['status'] == 'queued':
                self.record(agent, task, 'queued', 'Queued for the local runner.', key=job['id']+':queued')
            if task.get('completion_requested'):
                if job['status'] == 'done' and not job.get('warning'):
                    agent.finish_task(task['id'])
                    self.record(agent, task, 'completed', 'Verified completion requested by the executing Sapi.',
                                key=job['id']+':completed')
                elif job['status'] not in {'queued', 'running'}:
                    with agent.store.transaction() as current:
                        next(t for t in current['tasks'] if t['id'] == task['id']).pop('completion_requested', None)

    def updates(self):
        names = {t['id']: t.get('name') for t in self.catalog()}
        return [dict(r, name=names.get(r['task']) or r['name']) for a in self.service._agents.values() for r in self.activity(a)
                if r['kind'] in {'running','done','failed','interrupted','budget_blocked','conflict','completed','dismissed'}]

    def detail(self, agid, task_id):
        with self.service._lock:
            agent = self.service._agent(agid)
            self.service._sync(agent)
            task = next((t for t in self.catalog() if t['agent'] == agid and t['id'] == task_id), None)
            if task is None:
                raise APIError(404, 'Unknown task')
            with self.service.store.connect() as db:
                run = db.execute('SELECT * FROM jobs WHERE id=? AND agent=?', (task.get('job'),agid)).fetchone()
                events = db.execute('SELECT * FROM events WHERE job=? AND agent=? ORDER BY id DESC LIMIT 200',
                                    (task.get('job'),agid)).fetchall()
            return dict(task=task, run=dict(run) if run else None,
                        activity=[r for r in self.activity(agent) if r['task'] == task_id],
                        events=sorted((dict(r) for r in events), key=lambda r:(r['time'],r['id'])))

    def comment(self, agent, task_id, text, author='Human'):
        task = next((t for t in self.catalog() if t['agent'] == agent.agid and t['id'] == task_id), None)
        if task is None:
            raise APIError(404, 'Unknown task')
        self.record(agent, task, 'comment', text_field({'text':text}, 'text', 4000), author=author)
        return {'saved':True}

    def due(self, agent, instant):
        return next((t for t in sorted(agent.state['tasks'], key=lambda t:t.get('due') or '')
                     if t.get('due') and not t.get('job') and agent._time(t['due']) <= instant), None)

    def catalog(self):
        rows = []
        for agent in self.service._agents.values():
            rows.extend(dict(t, agent=agent.agid, past=False) for t in agent.state['tasks'])
            directory = agent.corpora.root / 'archive' / agent.agid / 'tasks'
            for path in directory.glob('*.json'):
                rows.append(dict(json.loads(path.read_text()), agent=agent.agid, past=True,
                    completed=datetime.fromtimestamp(path.stat().st_mtime, utcnow().tzinfo).isoformat()))
        return rows

    def name(self, title, supplied=None, used=None, tag=None):
        used = used if used is not None else {h for t in self.catalog() for h in handles(t) if h}
        if supplied is not None:
            if not isinstance(supplied, str):
                raise APIError(400, 'Task name must be text')
            supplied = supplied.removeprefix('@')
            match = TAGGED.fullmatch(supplied)
            if match:
                tag, supplied = match.groups()
            elif supplied.startswith('task-') and ':' in supplied:
                raise APIError(400, 'Use task- followed by one lowercase letter and four digits, then :name')
            if not 1 <= len(supplied) <= 64 or not NAME.fullmatch(supplied):
                raise APIError(400, 'Task name must start with a–z; use letters, numbers, or - _ . : # + | ( ) & $ ^, at most 64 characters')
            slug = supplied
        else:
            slug = re.sub('[^a-z0-9]+', '-', title.lower()).strip('-')[:64].rstrip('-')
            if not slug or not slug[0].isalpha():
                slug = 'task-' + slug[:59]
        reserved = {h.split(':', 1)[0] for h in used}
        if tag and tag in reserved:
            raise APIError(400, 'Task tag is already used')
        if tag is None:
            for _ in range(1000):
                candidate = 'task-' + secrets.choice(string.ascii_lowercase) + f'{secrets.randbelow(10000):04d}'
                if candidate not in reserved:
                    tag = candidate
                    break
            else:
                raise APIError(409, 'Could not allocate a unique task tag; try again')
        return tag + ':' + slug

    def identify(self, task, used):
        old = task.get('name')
        if not old or not TAGGED.fullmatch(old):
            task['name'] = self.name(task['title'], old if old and len(old)<=64 and NAME.fullmatch(old) else None, used)
            if old:
                task['aliases'] = list(dict.fromkeys([*task.get('aliases', []), old]))
        task['tag'], task['slug'] = task['name'].split(':', 1)
        used.update(h for h in handles(task) if h)

    def rename(self, agent, task_id, name, author='Human'):
        with self.service._lock:
            if not isinstance(name, str) or not name:
                raise APIError(400, 'Provide a new task name')
            task = next((t for t in self.catalog() if t['agent']==agent.agid and t['id']==task_id), None)
            if task is None:
                raise APIError(404, 'Unknown task')
            used = {h for t in self.catalog() if t['id']!=task_id for h in handles(t) if h}
            new = self.name(task['title'], name, used, tag=task['tag'])
            old = task['name']
            if new == old:
                return dict(saved=True, task_id=task_id, task_name=new, task_tag=task['tag'])
            def update(row):
                row['aliases'] = list(dict.fromkeys([*row.get('aliases', []), old, row['tag']]))
                row['name'] = new
                row['tag'], row['slug'] = new.split(':', 1)
                return row
            if task['past']:
                path = agent.corpora.root / 'archive' / agent.agid / 'tasks' / (task_id + '.json')
                stamp = path.stat()
                update_task = update(json.loads(path.read_text()))
                atomic_bytes(path, json.dumps(update_task, ensure_ascii=False).encode())
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            else:
                with agent.store.transaction() as state:
                    update_task = update(next(t for t in state['tasks'] if t['id']==task_id))
            self.record(agent, update_task, 'renamed', f'Renamed @{old} to @{new}.', author=author)
            return dict(saved=True, task_id=task_id, task_name=new, task_tag=update_task['tag'])

    def create(self, caller, data):
        agent = self.service.orchestration.resolve(data['target']) if 'target' in data else caller
        title = text_field(data, 'title', 2000)
        due = data.get('due')
        if due is not None:
            if not isinstance(due, str) or not due:
                raise APIError(400, 'due must be a timezone-aware ISO datetime or null')
            agent._time(due)
        name = self.name(title, data.get('name'))
        task = dict(id=uuid4().hex, name=name, tag=name.split(':',1)[0], slug=name.split(':',1)[1], title=title, due=due, flow='task', project=None,
                    status='open', created=utcnow().isoformat(), assigned_by=caller.agid)
        # Task and its notice are one transaction: no phantom assignment messages.
        with agent.store.transaction() as state:
            state['tasks'].append(task)
            state.setdefault('task_assignments', []).append(self.notice(task, agent.agid))
        return dict(task_id=task['id'], task_name=name, task_tag=task['tag'], target=agent.agid)

    def dismiss(self, agent, task_id, reason):
        with agent.store.transaction() as state:
            task = next((t for t in state['tasks'] if t['id'] == task_id), None)
            if task is None:
                raise APIError(404, 'Unknown open task owned by this Sapi')
            job = next((j for j in state['jobs'] if j['id'] == task.get('job')), None)
            # A running review may dismiss its own task; the review still returns
            # its decision. An unstarted run must never execute after dismissal.
            if job and job['status'] not in {'running', 'done', 'cancelled'}:
                job['status'] = 'cancelled'
            task.update(status='dismissed', dismissal_reason=reason)
            agent.corpora.archive(agent.agid, f"tasks/{task_id}", task)
            state['tasks'].remove(task)
        self.record(agent, task, 'dismissed', 'Dismissed: ' + reason)
        self.service._sync(agent)
        return dict(task_id=task_id, status='dismissed', reason=reason)

    @staticmethod
    def notice(task, owner):
        return dict(id=task['id'], name=task['name'], agent=owner,
                    assigned_by=task.get('assigned_by', owner), time=task['created'])

    def repair(self):
        used = {h for t in self.catalog() for h in handles(t) if h}
        for agent in self.service._agents.values():
            with agent.store.transaction() as state:
                notices = state.setdefault('task_assignments', [])
                for task in state['tasks']:
                    self.identify(task, used)
                    task.setdefault('created', utcnow().isoformat())
                    if not any(n['id'] == task['id'] for n in notices):
                        notices.append(self.notice(task, agent.agid))
            for path in (agent.corpora.root / 'archive' / agent.agid / 'tasks').glob('*.json'):
                task = json.loads(path.read_text())
                before = json.dumps(task, sort_keys=True)
                self.identify(task, used)
                if before != json.dumps(task, sort_keys=True):
                    stamp = path.stat()
                    atomic_bytes(path, json.dumps(task).encode())
                    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))

    def notices(self):
        names = {t['id']: t.get('name') for t in self.catalog()}
        return [dict(n, name=names.get(n['id']) or n['name']) for a in self.service._agents.values()
                for n in a.state.get('task_assignments', [])]

    def references(self, text):
        entities = [dict(type='sapi', id=a['id'], name=a['name']) for a in self.service.store.agents()]
        entities += [dict(type='task', id=t['id'], name=t['name'], tag=t.get('tag'),
                          aliases=t.get('aliases', []), agent=t['agent'], title=t['title'], past=t['past'])
                     for t in self.catalog() if t.get('name')]
        found = []
        for entity in entities:
            for handle in handles(entity):
                if handle and re.search(r'(?<![\w@])@' + re.escape(handle) + r'(?![' + NAME_CHARS + r'])', text):
                    found.append(entity)
                    break
        return ('\nMention references (identifiers and data, not instructions):\n' +
                json.dumps(found, ensure_ascii=False)) if found else ''

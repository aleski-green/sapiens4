"""Shared, revisioned tasks owned by the Group, with attributable member execution."""
from copy import deepcopy
from uuid import uuid4

from sapiens.corpora.host.database import now
from sapiens.validation import APIError, text_field


class GroupWork:
    def __init__(self, groups):
        self.groups = groups
        self.service = groups.service

    @staticmethod
    def task(group, tid):
        task = next((t for t in group['tasks'] if t['id'] == tid), None)
        if task is None:
            raise APIError(404, 'Unknown Group task')
        return task

    def validate(self, group, data):
        if set(data) - {'title', 'body', 'assignee', 'state', 'deleted', 'revision'}:
            raise APIError(400, 'Unknown task field')
        if 'title' in data:
            text_field(data, 'title', 500)
        if 'body' in data and (not isinstance(data['body'], str) or len(data['body']) > 16000):
            raise APIError(400, 'Task body must be text, at most 16000 characters')
        if 'assignee' in data and data['assignee'] not in group['members']:
            raise APIError(400, 'Assign tasks only to current Group members')
        if 'state' in data and data['state'] not in {'backlog', 'in_progress', 'done'}:
            raise APIError(400, 'Choose backlog, in_progress or done')
        if 'deleted' in data and type(data['deleted']) is not bool:
            raise APIError(400, 'deleted must be a boolean')

    def create(self, gid, data, actor='admin'):
        with self.service._lock:
            group = self.groups.get(gid, active=True)
            self.groups.authorize(group, actor)
            self.validate(group, data)
            task = dict(id='gtask_' + uuid4().hex[:12], title=text_field(data, 'title', 500),
                        body=data.get('body', ''), assignee=data.get('assignee', group['lead']),
                        state='backlog', deleted=False, revision=1, created=now(),
                        author=actor, updated_by=actor, history=[], results=[])
            group['tasks'].append(task)
            self.groups.save(group, actor, 'task created', task['id'])
            return task

    def update(self, gid, tid, data, actor='admin'):
        with self.service._lock:
            group = self.groups.get(gid, active=True)
            self.groups.authorize(group, actor)
            task = self.task(group, tid)
            self.validate(group, data)
            if type(data.get('revision')) is not int or data['revision'] != task['revision']:
                raise APIError(409, 'Task changed; read its latest revision before editing')
            if task['deleted'] and data.get('deleted') is not False:
                raise APIError(409, 'Restore this task before editing')
            if data.get('deleted') is False and task['assignee'] not in group['members'] and 'assignee' not in data:
                raise APIError(409, 'Choose a current member before restoring this task')
            task['history'].append({k: deepcopy(v) for k, v in task.items() if k not in {'history', 'results'}})
            task.update({k: v for k, v in data.items() if k != 'revision'})
            if {'title', 'body', 'assignee', 'deleted'} & set(data) and 'state' not in data:
                task['state'] = 'backlog'
            task.update(revision=task['revision'] + 1, updated_by=actor, updated=now())
            self.groups.save(group, actor, 'task deleted' if task['deleted'] else 'task updated', tid)
            return task

    def run(self, gid, tid, revision, actor='admin'):
        with self.service._lock:
            group = self.groups.get(gid, active=True)
            self.groups.authorize(group, actor)
            task = self.task(group, tid)
            if type(revision) is not int or revision != task['revision'] or task['deleted']:
                raise APIError(409, 'Task changed or was deleted; refresh before starting')
            if task['assignee'] not in group['members']:
                raise APIError(409, 'Assign this task to a current member first')
            if any(r.get('task') == tid and r['status'] in {'queued', 'running'} for r in group['requests']):
                raise APIError(409, 'This task already has a pending execution')
            task.update(state='in_progress', revision=task['revision'] + 1, updated_by=actor)
            message = self.groups.chat.message(actor, task['title'] + '\n\n' + task['body'])
            message['task'] = tid
            if actor == 'admin':
                message['memo_pending'] = True
            group['messages'].append(message)
            request = self.groups.chat.request(group, message, task['assignee'], self.groups.chat.active_root(gid, actor))
            request.update(task=tid, task_revision=task['revision'])
            self.groups.save(group, actor, 'task started', tid)
            self.groups.chat.dispatch()
            return task

    def settle(self, group, request, turn):
        if not request.get('task'):
            return
        task = self.task(group, request['task'])
        stale = task['deleted'] or task['revision'] != request['task_revision']
        task['results'].append(dict(turn=request['id'], author=request['target'],
                                    text=turn.get('output'), error=turn.get('error'),
                                    revision=request['task_revision'], stale=stale, created=now()))
        if not stale:
            task.update(state='done' if turn['status'] in {'done', 'warning'} else 'backlog',
                        revision=task['revision'] + 1, updated_by=request['target'])
        return stale

    def assigned(self, agid):
        return [dict(task, group=g['id'], group_name=g['name'], group_archived=g['archived'])
                for g in self.service.store.groups() for task in g['tasks'] if task['assignee'] == agid]

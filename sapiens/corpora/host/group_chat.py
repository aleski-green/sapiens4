"""Durable Group messages, addressed calls, and isolated shared conversation context."""
from uuid import uuid4
import json
import re

from sapiens.corpora.host.database import now
from sapiens.corpora.sapis.attachments import resolve_attachments, attachment_prompt
from sapiens.prompts import prompt
from sapiens.runtime.settings import execution_settings
from sapiens.validation import APIError


class GroupChat:
    def __init__(self, groups):
        self.groups, self.service = groups, groups.service

    @staticmethod
    def message(author, text):
        return dict(id=uuid4().hex, author=author, text=text, created=now())

    def mentions(self, group, text):
        recipients = []
        rows = self.service.store.agents()
        for row in rows:
            if row['id'] not in group['members']:
                continue
            # Explicit @names only; ordinary names and substrings do not dispatch.
            pattern = r'(?<![\w@])@' + re.escape(row['name']) + r'(?![\w:#+|()&$^\-]|\.[\w])'
            if re.search(pattern, text):
                if sum(a['name'] == row['name'] for a in rows if a['id'] in group['members']) != 1:
                    raise APIError(400, 'Ambiguous mention; address the member by target ID')
                recipients.append(row['id'])
        return recipients

    def request(self, group, message, target, root=None):
        request = dict(id=uuid4().hex, message=message['id'], target=target, status='queued',
                       root=root or message['id'], created=now(), settled=False)
        group['requests'].append(request)
        return request

    def submit(self, gid, data, actor='admin'):
        with self.service._lock:
            group = self.groups.get(gid, active=True)
            self.groups.authorize(group, actor)
            if set(data) - {'text', 'target', 'attachments'}:
                raise APIError(400, 'Group messages accept text and optional target')
            text = data.get('text', '')
            if not isinstance(text, str) or len(text) > 16000:
                raise APIError(400, 'Message must be text, at most 16000 characters')
            text = text.strip()
            attachments = resolve_attachments(self.service, gid, data.get('attachments', []))
            if not text and not attachments:
                raise APIError(400, 'Write a message or attach a file')
            targets = [data['target']] if 'target' in data else self.mentions(group, text)
            if any(t not in group['members'] for t in targets):
                raise APIError(400, 'Address only current Group members')
            if actor == 'admin' and not targets:
                targets = [group['lead']]
            message = self.message(actor, text)
            message['attachments'] = attachments
            group['messages'].append(message)
            for target in dict.fromkeys(targets):
                if target != actor:
                    self.request(group, message, target)
            self.groups.save(group, actor, 'message', message['id'])
            self.dispatch()
            return message

    def find(self, turn_id):
        for group in self.service.store.groups():
            for request in group['requests']:
                if request['id'] == turn_id:
                    return group, request
        return None, None

    def dispatch(self):
        with self.service._lock:
            if self.service._stopping.is_set():
                return
            for group in self.service.store.groups():
                if group['archived']:
                    continue
                for request in group['requests']:
                    if request['status'] != 'queued':
                        continue
                    agid = request['target']
                    agent = self.service._agent(agid)
                    if self.service.store.projected_turn(request['id']):
                        continue
                    if agid in self.service._runners or any(t['status'] in {'queued', 'running'} for t in agent.state['turns']):
                        continue
                    if any(c['addressedTo'] == agid and c['state'] == 'Queued'
                           for w in self.service.store.workloads() for c in w['calls']):
                        continue
                    message = next(m for m in group['messages'] if m['id'] == request['message'])
                    agent.runner.submit('chat', message['text'] + attachment_prompt(message.get('attachments', [])), turn_id=request['id'],
                                        origin=dict(group=group['id'], author=message['author']))
                    self.service._sync(agent)
                    self.service._queue.put(agid)

    def run(self, agid, runner, turn, snapshot, result):
        with self.service._lock:
            group, request = self.find(turn['id'])
            if group['archived'] or agid not in group['members']:
                raise APIError(409, 'Group is archived or membership changed before execution')
            request['status'] = 'running'
            self.service.store.save_group(group)
            manifests = runner.store.manifests
            # Personal chat, other groups' work and private host-facts are not copied into shared context.
            context = dict(group=dict(id=group['id'], name=group['name'], description=group['description'],
                                      lead=group['lead'], members=group['members'], workspace=str(self.groups.folder(group['id']))),
                           self_id=agid, chief_id=self.service.registry.main,
                           members=[a for a in self.service.store.agents() if a['id'] in group['members']],
                           tasks=[{k: t[k] for k in ('id', 'title', 'assignee', 'state', 'revision', 'deleted')}
                                  for t in group['tasks'][-50:]],
                           messages=group['messages'][-30:], request=request,
                           identity=manifests.get('identity'), host_control=manifests.get('host-control'),
                           computer=manifests.get('computer-use'))
            while True:
                rendered = prompt('group-conversation', context=json.dumps(context, ensure_ascii=False), task=turn['input'])
                if len(rendered) <= 60000 or not context['messages']:
                    break
                context['messages'].pop(0)
                context['history_truncated'] = True
        return runner.invoke(rendered, 'group', result,
                             timeout_seconds=execution_settings(runner.store.root)['timeout_seconds'])

    def reconcile(self):
        with self.service._lock:
            for group in self.service.store.groups():
                changed = False
                for request in list(group['requests']):
                    turn = self.service.store.projected_turn(request['id'])
                    if not turn:
                        if request['status'] == 'cancelled' and not request['settled']:
                            self.groups.work.settle(group, request, dict(status='cancelled', error='Group archived'))
                            request['settled'] = True
                            changed = True
                        continue
                    if request['status'] != turn['status']:
                        request['status'] = turn['status']
                        changed = True
                    if turn['status'] in {'queued', 'running'} or request['settled']:
                        continue
                    request['settled'] = True
                    changed = True
                    stale = self.groups.work.settle(group, request, turn)
                    if turn['output'] is not None:
                        message = self.message(request['target'], turn['output'])
                        message.update(turn=request['id'], stale=bool(stale))
                        group['messages'].append(message)
                        # A Lead can call each member once within this Admin request. Replies
                        # from members do not create an unbounded mention ping-pong.
                        if request['target'] == group['lead'] and not group['archived']:
                            called = {r['target'] for r in group['requests'] if r['root'] == request['root']}
                            try:
                                targets = self.mentions(group, turn['output'])
                            except APIError:
                                targets = []
                            for target in targets:
                                if target not in called:
                                    self.request(group, message, target, request['root'])
                    if turn.get('error'):
                        request['error'] = turn['error']
                    group['events'].append(dict(id=uuid4().hex, actor=request['target'],
                        action='result needs review' if stale else 'call ' + turn['status'],
                        detail=request['id'], created=now()))
                if changed:
                    group['revision'] += 1
                    group['updated'] = now()
                    self.service.store.save_group(group)

    def action(self, gid, rid, action):
        with self.service._lock:
            group = self.groups.get(gid, active=action == 'retry')
            request = next((r for r in group['requests'] if r['id'] == rid), None)
            if request is None:
                raise APIError(404, 'Unknown Group call')
            turn = self.service.store.projected_turn(rid)
            if action == 'cancel' and turn is None:
                request.update(status='cancelled')
                self.groups.save(group, 'admin', 'call cancelled', rid)
            elif turn:
                if action == 'retry':
                    if request['target'] not in group['members']:
                        raise APIError(409, 'The recipient is no longer a Group member')
                    if request.get('task'):
                        raise APIError(409, 'Start the current task revision from Work instead')
                self.service.turn_action(request['target'], rid, action)
                group = self.groups.get(gid)
                request = next(r for r in group['requests'] if r['id'] == rid)
                if action == 'retry':
                    request.update(settled=False, status='queued')
                    request.pop('error', None)
                    self.groups.save(group, 'admin', 'call retried', rid)
                else:
                    self.groups.save(group, 'admin', 'call cancelled', rid)
            else:
                raise APIError(400, 'Only failed or interrupted calls can be retried')
            self.reconcile()
            self.dispatch()
            return dict(saved=True)

"""Group identity, membership and lifecycle; records are serialized by the host lock."""
from copy import deepcopy
from types import SimpleNamespace
from uuid import uuid4
import secrets

from sapiens.corpora.host.database import now
from sapiens.corpora.host.group_chat import GroupChat
from sapiens.corpora.host.group_work import GroupWork
from sapiens.validation import APIError, text_field
from sapiens.corpora.sapis.notes import Notes


class Groups:
    def __init__(self, service):
        self.service = service
        self.chat = GroupChat(self)
        self.work = GroupWork(self)

    def get(self, gid, active=False):
        group = next((g for g in self.service.store.groups() if g['id'] == gid), None)
        if group is None:
            raise APIError(404, 'Unknown Group')
        if active and group['archived']:
            raise APIError(409, 'Restore this Group before changing its work')
        return group

    def save(self, group, actor, action, detail):
        group['revision'] += 1
        group['updated'] = now()
        group['events'].append(dict(id=uuid4().hex, actor=actor, action=action,
                                    detail=detail, created=group['updated']))
        self.service.store.save_group(group)

    def authorize(self, group, actor, management=False, chief=False):
        if actor == 'admin':
            return
        self.service.lifecycle.require_active(self.service._agent(actor))
        if chief:
            allowed = actor == self.service.registry.main
        elif management:
            allowed = actor in (self.service.registry.main, group['lead'])
        else:
            allowed = actor in group['members']
        if not allowed:
            raise APIError(403, 'Only Chief can perform this operation' if chief else
                           'Only Chief or the Lead can manage members' if management else
                           'Only Group members can contribute')

    def members(self, value, lead):
        if not isinstance(value, list) or not 2 <= len(value) <= 100 or any(not isinstance(v, str) for v in value):
            raise APIError(400, 'A Group needs 2–100 distinct Sapis, including its Lead')
        if len(set(value)) != len(value) or lead not in value:
            raise APIError(400, 'Members must be distinct and include exactly one Lead')
        for agid in value:
            self.service.lifecycle.require_active(self.service._agent(agid))
        return value

    def check_capacity(self, members, exclude=None):
        groups = [g for g in self.service.store.groups() if not g['archived'] and g['id'] != exclude]
        for member in members:
            if sum(member in g['members'] for g in groups) >= 11:
                raise APIError(409, 'A Sapi can belong to at most 11 active Groups')

    def create(self, data, actor='admin'):
        with self.service._lock:
            self.authorize(None, actor, chief=True)
            if set(data) - {'name', 'description', 'lead', 'members'}:
                raise APIError(400, 'Unknown Group field')
            name = text_field(data, 'name', 60)
            description = data.get('description', '')
            if not isinstance(description, str) or len(description) > 2000:
                raise APIError(400, 'Description must be text, at most 2000 characters')
            lead = data.get('lead')
            members = self.members(data.get('members'), lead)
            self.check_capacity(members)
            order = [m for m in members if m != lead]
            secrets.SystemRandom().shuffle(order)
            group = dict(id='group_' + uuid4().hex[:12], name=name, description=description,
                         lead=lead, members=members, strip_order=[lead, *order],
                         color=secrets.choice(['#48c99c', '#ba85df', '#74b9ed', '#edbd65', '#e891ae']),
                         archived=False, created=now(), updated=now(),
                         revision=0, messages=[], requests=[], tasks=[], events=[])
            self.save(group, actor, 'created', name)
            self.folder(group['id'])
            return group

    def update(self, gid, data, actor='admin'):
        with self.service._lock:
            group = self.get(gid)
            if set(data) - {'name', 'description', 'members', 'lead', 'archived', 'revision'}:
                raise APIError(400, 'Unknown Group field')
            self.authorize(group, actor, management=True)
            if type(data.get('revision')) is not int or data['revision'] != group['revision']:
                raise APIError(409, 'Group changed; refresh before saving')
            if 'lead' in data and data['lead'] != group['lead'] or 'archived' in data:
                self.authorize(group, actor, chief=True)
            if 'archived' in data and type(data['archived']) is not bool:
                raise APIError(400, 'archived must be a boolean')
            if group['archived'] and data.get('archived') is not False:
                raise APIError(409, 'Restore this Group before editing it')
            lead = data.get('lead', group['lead'])
            members = self.members(data.get('members', group['members']), lead)
            if not data.get('archived', group['archived']):
                self.check_capacity(members, exclude=gid)
            removed = set(group['members']) - set(members)
            if any(r['target'] in removed and r['status'] in {'queued', 'running'} for r in group['requests']):
                raise APIError(409, 'Finish or cancel the departing member’s Group calls first')
            if any(t['assignee'] in removed and not t['deleted'] and t['state'] != 'done' for t in group['tasks']):
                raise APIError(409, 'Reassign the departing member’s unfinished tasks first')
            changed_lead = lead != group['lead']
            for key in ('name', 'description'):
                if key in data:
                    if key == 'name':
                        group[key] = text_field(data, key, 60)
                    elif not isinstance(data[key], str) or len(data[key]) > 2000:
                        raise APIError(400, 'Description must be text, at most 2000 characters')
                    else:
                        group[key] = data[key]
            old_order = [m for m in group['strip_order'] if m in members and m != lead]
            additions = [m for m in members if m != lead and m not in old_order]
            secrets.SystemRandom().shuffle(additions)
            group.update(lead=lead, members=members, strip_order=[lead, *old_order, *additions])
            group['archived'] = data.get('archived', group['archived'])
            if group['archived']:
                # Unstarted work is cancelled; running work may finish and remains attributable.
                for request in group['requests']:
                    if request['status'] == 'queued':
                        turn = self.service.store.projected_turn(request['id'])
                        if turn and turn['status'] == 'running':
                            request['status'] = 'running'
                        else:
                            if turn and turn['status'] == 'queued':
                                self.service._agent(request['target']).runner.cancel(request['id'])
                            request['status'] = 'cancelled'
            action = 'leadership transferred' if changed_lead else ('archived' if group['archived'] else 'updated')
            self.save(group, actor, action, dict(lead=lead, members=members))
            return group

    def folder(self, gid):
        self.get(gid)
        path = self.service.root / 'workspaces' / gid
        path.mkdir(parents=True, exist_ok=True)
        return path

    def workspace_owner(self, gid):
        self.get(gid)
        return SimpleNamespace(agid=gid)

    def snapshot(self):
        rows = self.service.store.groups()
        agents = {a['id']: a for a in self.service.store.agents()}
        for group in rows:
            group.update(kind='group', role=group['description'] or 'Shared Group workspace',
                         face=agents[group['lead']]['face'],
                         stripes=[agents[m]['color'] for m in group['strip_order']],
                         workspace=str(self.folder(group['id'])),
                         notes=Notes(self.folder(group['id'])).metadata())
        return rows

    def facts(self, actor):
        return [dict(id=g['id'], name=g['name'], lead=g['lead'], members=g['members'],
                     revision=g['revision'], workspace=str(self.folder(g['id'])),
                     tasks=deepcopy(g['tasks'])) for g in self.service.store.groups()
                if not g['archived'] and (actor in g['members'] or actor == self.service.registry.main)]

    def control(self, actor, data):
        op = data['op']
        payload = {k: v for k, v in data.items() if k not in {'op', 'group'}}
        if op == 'group_create':
            return self.create(payload, actor)
        gid = data.get('group')
        if op == 'group_update':
            return self.update(gid, payload, actor)
        group = self.get(gid, active=op != 'group_get')
        self.authorize(group, actor)
        if op == 'group_get':
            return group
        if op == 'group_message':
            return self.chat.submit(gid, payload, actor)
        if op == 'group_task_create':
            return self.work.create(gid, payload, actor)
        if op == 'group_task_update':
            return self.work.update(gid, payload.pop('task', None), payload, actor)
        if op == 'group_task_run':
            return self.work.run(gid, payload.get('task'), payload.get('revision'), actor)
        raise APIError(400, 'Unknown Group operation')

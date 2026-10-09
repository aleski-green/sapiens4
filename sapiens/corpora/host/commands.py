"""Validated team and workspace operations for conversational Sapis."""
import json
import shlex
import sys

from sapiens.corpora.sapis.notes import Notes
from sapiens.paths import ROOT
from sapiens.prompts import prompt
from sapiens.files import atomic_bytes
from sapiens.validation import APIError, sapi_name, text_field


class Orchestration:
    def __init__(self, service):
        self.service = service
        self.url = None

    def settings(self, agent):
        path = agent.root / "host.json"
        saved = json.loads(path.read_text()) if path.exists() else {}
        return {k: saved[k] for k in ('retired_at', 'retirement_reason') if k in saved}

    @staticmethod
    def save(agent, settings):
        atomic_bytes(agent.root / "host.json", json.dumps(settings).encode())

    def attach(self, url):
        self.url = url
        for agent in self.service._agents.values():
            self.prepare(agent)


    def resolve(self, value, include_retired=False):
        rows = self.service.store.agents()
        matches = [r for r in rows if r["id"] == value]
        if not matches and isinstance(value, str):
            matches = [r for r in rows if r["name"].casefold() == value.casefold()]
        if len(matches) != 1:
            raise APIError(400, "Sapi name must identify exactly one existing Sapi; use its ID")
        agent = self.service._agent(matches[0]["id"])
        if not include_retired:
            self.service.lifecycle.require_active(agent)
        return agent


    def control(self, agid, data):
        run_id = data.get('agencyRun')
        if run_id is None:
            return self._control(agid, data)
        with self.service._lock:
            if not any(t['id'] == run_id and t['status'] == 'running'
                       for t in self.service._agent(agid).state['turns']):
                raise APIError(409, 'AgencyRun is no longer active')
            previous = getattr(self.service._execution, 'turn', None)
            self.service._execution.turn = run_id
            try:
                return self._control(agid, {k: v for k, v in data.items() if k != 'agencyRun'})
            finally:
                self.service._execution.turn = previous

    def _control(self, agid, data):
        with self.service._lock:
            agent = self.service._agent(agid)
            op = data.get("op")
            fields = {"batch": {"operations"}, "status": {'target'},
                      "delegate": {'decision'},
                      "routines": set(), "routine_create": {"minutes", "prompt"},
                      "routine_update": {"id", "minutes", "prompt"},
                      "routine_pause": {"id"}, "routine_resume": {"id"},
                      "group_create": {'name', 'description', 'lead', 'members'},
                      "group_get": {'group'},
                      "group_update": {'group', 'revision', 'name', 'description', 'lead', 'members', 'archived'},
                      "group_message": {'group', 'text', 'target'},
                      "group_task_create": {'group', 'title', 'body', 'assignee'},
                      "group_task_update": {'group', 'task', 'revision', 'title', 'body', 'assignee', 'state', 'deleted'},
                      "group_task_run": {'group', 'task', 'revision'},
                      "create_agent": {"name", "role", "manager"},
                      "retire_agent": {"target", "reason"}, "rehire_agent": {"target"},
                      "computer_acquire": set(), "manager": {"manager", "target"},
                      "workspace": {'group'}, "workspace_open": {"url", "path", "id", "group"},
                      **{"workspace_" + action: {"id", "group"} for action in
                         ("close", "focus", "reload", "back", "forward", "bookmark", "unbookmark")},
                      "workspace_zoom": {"id", "factor", "group"}}
            if not isinstance(op, str) or op not in fields or set(data) - fields[op] - {"op"}:
                raise APIError(400, "Unknown operation or field")
            if op not in {'status', 'workspace'} and not op.startswith('workspace_'):
                self.service.lifecycle.require_active(agent)
            if op == 'batch':
                operations = data.get('operations')
                if not isinstance(operations, list) or not 1 <= len(operations) <= 20:
                    raise APIError(400, 'Provide 1–20 operations')
                for item in operations:
                    if not isinstance(item, dict) or not isinstance(item.get('op'), str) or item['op'] not in fields or item['op'] == 'batch' or set(item) - fields[item['op']] - {'op'}:
                        raise APIError(400, 'Invalid batch operation or field; nested batches are not supported')
                results = []
                for index, item in enumerate(operations):
                    try:
                        results.append(self.control(agid, item))
                    except APIError as error:
                        return {'self_id': agid, 'saved': False, 'results': results,
                                'failed_index': index, 'error': str(error), 'status': error.status,
                                'partial': bool(results)}
                return {'self_id': agid, 'saved': True, 'results': results}
            result = {}
            workspace_owner = agent
            if data.get('group') and (op == 'workspace' or op.startswith('workspace_')):
                group = self.service.groups.get(data['group'], active=True)
                self.service.groups.authorize(group, agid)
                workspace_owner = self.service.groups.workspace_owner(group['id'])
            if op.startswith("group_"):
                return self.service.groups.control(agid, data)
            if op == 'routines':
                return {'routines': [r for r in self.service.store.routines() if r['owner'] == agid]}
            if op in {'routine_pause', 'routine_resume'}:
                routine = self.service.routines.set_paused(agid, text_field(data, 'id', 80), op == 'routine_pause')
                return {'self_id': agid, 'saved': True, 'routine': routine}
            if op in {'routine_create', 'routine_update'}:
                routine = self.service.routines.save(agid, data.get('minutes'), data.get('prompt'),
                    routine_id=text_field(data, 'id', 80) if op == 'routine_update' else None, source_call=self.service._active_turn(agid))
                return {'self_id': agid, 'saved': True, 'routine': routine}
            if op == 'delegate':
                return self.service.delegation.apply(agid, data.get('decision'))
            if op == 'computer_acquire':
                return self.service.acquire_computer(agid)
            if op == 'workspace':
                return self.service.workspace.summary(workspace_owner)
            if op == 'status':
                target = self.resolve(data['target'], include_retired=True) if 'target' in data else agent
                return self.status(target)
            if op in {'retire_agent', 'rehire_agent'}:
                if agent.agid != self.service.registry.main:
                    raise APIError(403, 'Only the main Sapi can retire or rehire Sapis through host-control')
                target = self.resolve(data.get('target'), include_retired=True)
                result = self.service.lifecycle.change(target.agid, op == 'retire_agent', data.get('reason', ''))
            elif op == 'create_agent':
                if agent.agid != self.service.registry.main:
                    raise APIError(403, 'Only the main Sapiens can create agents through host-control')
                name, role = sapi_name(data), text_field(data, 'role', 60)
                matches = [r for r in self.service.store.agents() if r['name'].casefold() == name.casefold()]
                parent = self.resolve(data['manager']).agid if data.get('manager') is not None else agent.agid
                if matches:
                    if len(matches) != 1 or matches[0]['role'] != role or matches[0]['id'] == agent.agid:
                        raise APIError(409, 'Name already exists with a different role; use status to inspect it')
                    child = self.service._agent(matches[0]['id'])
                    self.service.lifecycle.require_active(child)
                    if self.service.registry.directory()[child.agid]['parent'] != parent:
                        raise APIError(409, 'Name already exists with a different manager')
                    result = {'agent': matches[0], 'created': False}
                else:
                    result = {'agent': self.service.create_agent(dict(name=name, role=role, manager=parent)), 'created': True}
                self.prepare(self.service._agent(result['agent']['id']))
            elif op.startswith('workspace_'):
                result['workspace'] = self.service.workspace.control(workspace_owner, op.removeprefix('workspace_'), data)
            elif op == "manager":
                if "manager" not in data:
                    raise APIError(400, "manager is required; use null to clear it")
                target = self.resolve(data["target"]) if "target" in data else agent
                parent = self.service.registry.validate(target.agid, data["manager"])
                self.service.registry.assign(target, parent)
                result = {"target": target.agid, "manager": parent}
            # Mutation receipts should not append the entire team history on
            # every tool step (or truncate the actual saved result at the end).
            receipt = {'self_id': agent.agid, 'saved': True, **result}
            return receipt


    def prepare(self, agent):
        if self.url:
            path = self.service.workspace.root(agent) / 'host-control.json'
            atomic_bytes(path, json.dumps({'url': f'{self.url}/api/agents/{agent.agid}/control'}).encode())
            command = ' '.join(shlex.quote(str(p)) for p in (sys.executable, ROOT / 'sapiens/corpora/host/client.py', path))
            agent.set_manifest('host-control', prompt('host-control', command=command))
        facts = self.status(agent)
        facts['notes'] = Notes(self.service.workspace.root(agent)).context()
        agent.set_manifest('host-facts', json.dumps(facts, ensure_ascii=False))

    def team(self):
        result = []
        for row in self.service.store.agents():
            agent = self.service._agent(row['id'])
            if not self.service.lifecycle.retired(agent):
                result.append(dict(id=row['id'], name=row['name'], role=row['role'],
                    manager=self.service.registry.directory().get(agent.agid, {}).get('parent'),
                    busy=any(t['status'] in {'queued','running'} for t in agent.state['turns'])))
        return result

    def status(self, agent):
        return dict(self_id=agent.agid, main_agent_id=self.service.registry.main,
                    team=self.team(), retired_team=self.service.lifecycle.catalog(),
                    groups=self.service.groups.facts(agent.agid),
                    workspace=self.service.workspace.summary(agent),
                    notes=Notes(self.service.workspace.root(agent)).metadata())

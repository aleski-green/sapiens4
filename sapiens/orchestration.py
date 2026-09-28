"""Validated team and workspace operations for conversational Sapis."""
import json
import shlex
import sys

from .diagnostics import report
from .execution import read
from .notes import Notes
from .paths import ROOT
from .sdk import atomic_bytes
from .validation import APIError, sapi_name, text_field


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
        with self.service._lock:
            agent = self.service._agent(agid)
            op = data.get("op")
            fields = {"batch": {"operations"}, "status": {'target'}, "budget_diagnostics": {'target', 'offset', 'limit'},
                      "create_agent": {"name", "role", "manager"},
                      "retire_agent": {"target", "reason"}, "rehire_agent": {"target"},
                      "execution": set(), "computer_acquire": set(), "manager": {"manager", "target"},
                      "workspace": set(), "artifact_save": {"name", "content", "path", "title", "open"},
                      "artifact_read": {"name"}, "workspace_open": {"artifact", "url", "title", "id"},
                      "workspace_close": {"id"}}
            if not isinstance(op, str) or op not in fields or set(data) - fields[op] - {"op"}:
                raise APIError(400, "Unknown operation or field")
            if op not in {'status', 'workspace', 'workspace_open', 'workspace_close',
                          'artifact_read', 'budget_diagnostics', 'execution'}:
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
            if op == 'budget_diagnostics':
                targets = [self.resolve(data['target'])] if 'target' in data else [
                    self.service._agent(row['id']) for row in self.service.store.agents()]
                return report(self.service, targets, data.get('offset', 0), data.get('limit', 10))
            if op == 'computer_acquire':
                return self.service.acquire_computer(agid)
            if op == 'execution':
                return {'execution': read(self.service.workspace.root(agent))}
            if op == 'workspace':
                return self.service.workspace.summary(agent)
            if op == 'artifact_read':
                return self.service.workspace.read(agent, data.get('name'))
            if op == 'status':
                target = self.resolve(data['target'], include_retired=True) if 'target' in data else agent
                return self.status(target)
            if op in {'retire_agent', 'rehire_agent'}:
                if agent.agid != self.service.hierarchy.main:
                    raise APIError(403, 'Only the main Sapi can retire or rehire Sapis through host-control')
                target = self.resolve(data.get('target'), include_retired=True)
                result = self.service.lifecycle.change(target.agid, op == 'retire_agent', data.get('reason', ''))
            elif op == 'create_agent':
                if agent.agid != self.service.hierarchy.main:
                    raise APIError(403, 'Only the main Sapiens can create agents through host-control')
                name, role = sapi_name(data), text_field(data, 'role', 60)
                matches = [r for r in self.service.store.agents() if r['name'].casefold() == name.casefold()]
                parent = self.resolve(data['manager']).agid if data.get('manager') is not None else agent.agid
                if matches:
                    if len(matches) != 1 or matches[0]['role'] != role or matches[0]['id'] == agent.agid:
                        raise APIError(409, 'Name already exists with a different role; use status to inspect it')
                    child = self.service._agent(matches[0]['id'])
                    self.service.lifecycle.require_active(child)
                    if child.corpora.directory()[child.agid]['parent'] != parent:
                        raise APIError(409, 'Name already exists with a different manager')
                    result = {'agent': matches[0], 'created': False}
                else:
                    result = {'agent': self.service.create_agent(dict(name=name, role=role, manager=parent)), 'created': True}
                self.prepare(self.service._agent(result['agent']['id']))
            elif op == 'artifact_save':
                result['artifact'] = self.service.workspace.save(agent, data)
            elif op == 'workspace_open':
                result['tab'] = self.service.workspace.open(agent, data)
            elif op == 'workspace_close':
                result.update(self.service.workspace.close(agent, data.get('id')))
            elif op == "manager":
                if "manager" not in data:
                    raise APIError(400, "manager is required; use null to clear it")
                target = self.resolve(data["target"]) if "target" in data else agent
                parent = self.service.hierarchy.validate(target.agid, data["manager"])
                self.service.hierarchy.assign(target, parent)
                result = {"target": target.agid, "manager": parent}
            if op != "status":
                audit = {k: v for k, v in data.items() if k != 'content'}
                self.service.store.event(agid, "control", json.dumps(audit), turn=self.service._active_turn(agid))
            # Mutation receipts should not append the entire team history on
            # every tool step (or truncate the actual saved result at the end).
            receipt = {'self_id': agent.agid, 'saved': True, **result}
            return receipt


    def prepare(self, agent):
        if self.url:
            path = self.service.workspace.root(agent) / 'host-control.json'
            atomic_bytes(path, json.dumps({'url': f'{self.url}/api/agents/{agent.agid}/control'}).encode())
            command = ' '.join(shlex.quote(str(p)) for p in (sys.executable, ROOT / 'sapiens/control.py', path))
            agent.set_manifest('host-control', f"""Run {command} '<JSON object>' for internal operations.
Quote JSON safely. Use op plus these fields:
- status: optional target (unique Sapi name or ID). Team, retired_team, workspace and notes path.
- batch: operations (1–20 operation objects, no nesting). Runs in order. Check saved,
  results and failed_index; after a partial failure retry only unsaved operations.
- create_agent: name (1–24 chars, begins A–Z, no spaces), role (1–60 chars), optional
  manager (name or ID). Chief only. Same name/role/manager reuses an existing Sapi.
- retire_agent: target, optional reason. Chief only, when Admin requests it.
  Preserves history and notes; cannot retire the chief, a busy Sapi or a manager
  with active direct reports. Reassign those reports first.
- rehire_agent: target. Chief only, when Admin requests it. Reuses the saved ID.
- manager: manager (name/ID, or null for chief), optional target.
- budget_diagnostics: optional target, offset, limit (1–20). Current allowances,
  execution errors, and charges with unknown usage. Read this before investigating source.
- execution: current deadline, remaining seconds/tool calls, and phase.
- workspace: your saved artifacts and open workspace tabs.
- artifact_save: name (filename .md/.html/.txt/.json), content OR path (UTF-8 file in
  your workspace), optional title, open (default true). Maximum 1 MB. Reuse the name
  to update. Receipt includes a stable @art- tag; use that exact tag in chat.
- artifact_read: name (filename or @art- tag). Returns at most 64000 characters.
- workspace_open: artifact (saved filename or tag) OR url (HTTP/S), optional title,
  id (existing tab to update). Returns the saved tab ID.
- workspace_close: id.
Notes.md is your plain-text file: manage it directly with file tools. Never edit
host-control.json, SQLite or state.json. Check receipts before claiming success.
Task scheduling, delegation, recurring jobs and consolidation are unavailable.
""")
        facts = self.status(agent)
        facts['notes'] = Notes(self.service.workspace.root(agent)).context()
        agent.set_manifest('host-facts', json.dumps(facts, ensure_ascii=False))

    def team(self):
        result = []
        for row in self.service.store.agents():
            agent = self.service._agent(row['id'])
            if not self.service.lifecycle.retired(agent):
                result.append(dict(id=row['id'], name=row['name'], role=row['role'],
                    manager=agent.corpora.directory().get(agent.agid, {}).get('parent'),
                    busy=any(t['status'] in {'queued','running'} for t in agent.state['turns']),
                    budget=agent.budget_status()))
        return result

    def status(self, agent):
        return dict(self_id=agent.agid, main_agent_id=self.service.hierarchy.main,
                    team=self.team(), retired_team=self.service.lifecycle.catalog(),
                    workspace=self.service.workspace.summary(agent),
                    notes=Notes(self.service.workspace.root(agent)).metadata())

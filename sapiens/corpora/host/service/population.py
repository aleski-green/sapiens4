from __future__ import annotations

from uuid import uuid4
import json
import os
import re
import secrets
from sapiens.corpora.sapis.attachments import attachment_prompt, resolve_attachments
from sapiens.prompts import prompt
from sapiens.corpora.sapis.notes import Notes
from sapiens.corpora.sapis.conversations import Config, Conversation, computer_manifest
from sapiens.runtime.codex import CodexFactory
from sapiens.runtime.settings import codex_binary, execution_settings
from sapiens.runtime.turns import TurnRunner
from sapiens.computer.focus import ForegroundReturn
from sapiens.files import atomic_bytes
from sapiens.corpora.host.database import now
from sapiens.validation import APIError, sapi_name, text_field


def complete_with_computer(llm, text, finish=None):
    """Restore foreground before releasing the shared computer, including failures."""
    foreground = ForegroundReturn(llm.workdir)
    llm.warning = None
    try:
        return llm.complete(text)
    finally:
        llm.warning = finish(foreground.restore) if finish else foreground.restore()


def random_avatar(used):
    faces = [left + mouth + right for left, right in
             [("◕", "◕"), ("◠", "◠"), ("•", "•"), ("⌐■", "■"), ("≧", "≦"), ("◉", "◉"), ("^", "^"), ("¬", "¬")]
             for mouth in ["‿", "ᴗ", "ω", "▽", "ᵕ", "﹏", "o", "∇"]]
    available = [face for face in faces if face not in used]
    if not available:
        available = [f"{face}✦{secrets.token_hex(2)}" for face in faces]
    return dict(face=secrets.choice(available), color=secrets.choice(
        ["#d8e5f4", "#dbd0f7", "#fdd997", "#f7d6d1", "#c9f3f1", "#e1edc6"]))


class Population:
    def __init__(self, host):
        self.host = host
        self.agents: dict[str, Conversation] = {}

    def agent(self, agid):
        host = self.host
        if agid not in self.agents:
            row = next((a for a in host.store.agents() if a["id"] == agid), None)
            if row is None:
                raise APIError(404, "Unknown Sapi")
            workdir = host.root / "workspaces" / agid
            workdir.mkdir(parents=True, exist_ok=True)

            factory = (host.factory_builder(agid) if host.factory_builder else
                       CodexFactory(workdir=workdir))
            Notes(workdir).ensure(row['name'], row['role'])
            agent = Conversation(agid=agid, root=host.root / "agentpy")
            if agid not in host.registry.directory():
                host.registry.register(agid)
            complete = None
            if not host.factory_builder:
                complete = lambda llm, text: complete_with_computer(
                    llm, text, lambda restore: host.execution.release_computer(agid, restore))
            agent.runner = TurnRunner(store=agent, context=agent.context, config=Config(),
                                      factory=factory, complete=complete,
                                      execute=lambda runner, turn, snapshot, result: (host.groups.chat if (turn.get("origin") or {}).get("group") else host.delegation).run(agid, runner, turn, snapshot, result))
            if not host.factory_builder:
                factory.execution = lambda: execution_settings(agent.root)
            self.agents[agid] = agent
            self.manifests(agent, row)
        return self.agents[agid]

    def manifests(self, agent, row):
        agent.set_manifest('corpora-scope', self.host.corpora_settings.value['scope'])
        agent.set_manifest("identity", prompt('identity', name=row['name'], role=row['role'], face=row['face']))
        agent.set_manifest("computer-use", computer_manifest(self.host.binary))

    def create_agent(self, data):
        host = self.host
        name, role = sapi_name(data), text_field(data, "role", 60)
        color = data.get("color", "#d8e5f4")
        if not isinstance(color, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise APIError(400, "color must be a six-digit hex color")
        face = data.get("face", "◠‿◠")
        if not isinstance(face, str) or not 1 <= len(face) <= 24:
            raise APIError(400, "face must contain 1–24 characters")
        if data.get("kind", "sapi") != "sapi":
            raise APIError(400, "Use /api/groups to create a Group")
        with host._lock:
            appearance = random_avatar({a["face"] for a in host.store.agents()})
            if "face" in data and face not in {a["face"] for a in host.store.agents()}:
                appearance["face"] = face
            if "color" in data:
                appearance["color"] = color
            row = dict(id="sapi_" + uuid4().hex[:12], name=name, role=role,
                       **appearance, created=now())
            parent = host.registry.validate(row["id"], data.get("manager"))
            host.store.add_agent(row)
            host.registry.register(row["id"], parent=parent)
            agent = self.agent(row["id"])
            host.orchestration.settings(agent)
            host.store.events.record(row['id'], row['id'], 'sapi.created', dict(row, manager=parent))
            return row

    def update_agent(self, agid, data):
        host = self.host
        if set(data) - {"name", "role", "manager", "execution"}:
            raise APIError(400, "Unknown or inactive setting")
        policy = data.get('execution')
        if 'execution' in data and (not isinstance(policy, dict) or set(policy) != {'mode'}
                or policy['mode'] not in ('normal','deep')):
            raise APIError(400, 'Choose Normal or Deep work; call timeouts are managed globally')
        row = {"name": sapi_name(data), "role": text_field(data, "role", 60)}
        with host._lock:
            agent = self.agent(agid)
            host.lifecycle.require_active(agent)
            if any(j["status"] in {"queued", "running"} for j in agent.state["turns"]):
                raise APIError(409, "Wait for this Sapi's current turn before changing its identity")
            if "manager" in data:
                parent = host.registry.validate(agid, data["manager"])
                host.registry.assign(agent, parent)
            if policy is not None:
                atomic_bytes(agent.root / 'run-settings.json', json.dumps(policy).encode())
            host.store.update_agent(agid, row)
            host.store.events.record(agid, agid, 'sapi.updated', data)
            self.manifests(agent, next(a for a in host.store.agents() if a['id'] == agid))
        return {"id": agid, **row}

    def submit(self, agid, data):
        host = self.host
        raw_text = data.get("text", "")
        if not isinstance(raw_text, str) or len(raw_text) > 16000:
            raise APIError(400, "Message must be text, at most 16000 characters")
        text = raw_text.strip()
        attachments = resolve_attachments(host, agid, data.get("attachments", []))
        if not text and not attachments:
            raise APIError(400, "Write a message or attach a file")
        message = text + attachment_prompt(attachments)
        flow = data.get("flow", "chat")
        if flow not in ("chat", "computer"):
            raise APIError(400, "Choose chat or computer")
        if not host.factory_builder and not codex_binary():
            raise APIError(503, "Codex CLI is missing. Install it and run codex login.")
        if flow == "computer" and not host.factory_builder and not os.access(host.binary, os.X_OK):
            raise APIError(503, "Blindly4 is not built. Run ./start.sh to build it.")
        with host._lock:
            if host.execution.stopping.is_set():
                raise APIError(503, "Server is shutting down")
            agent = self.agent(agid)
            # A failed attempt remains reviewable; a new message is not a retry.
            host.lifecycle.require_active(agent)
            routine = host.routines.command(agid, text, attachments)
            if routine:
                return host.routines.acknowledge(agent, text, routine)
            if data.get('workload'):
                turn = host.delegation.clarify(agid, data['workload'], message)
            else:
                turn = agent.runner.submit(flow, message, batchable=True)
            host.store.message(turn, text, attachments)
            host.projection.sync(agent)
            host.execution.queue.put(agid)
            return {"id": turn, "agent": agid, "status": "queued", "flow": flow}

    def turn_action(self, agid, turn_id, action):
        host = self.host
        with host._lock:
            agent = self.agent(agid)
            host.lifecycle.require_active(agent)
            turns = agent.state["turns"]
            turn = next((j for j in turns if j["id"] == turn_id), None)
            if turn is None:
                raise APIError(404, "Unknown active turn")
            work, call = host.delegation.find(turn_id)
            if call and any(c['causedBy'] == turn_id for c in work['calls']):
                raise APIError(409, 'This request was delegated; use the recipient call controls')
            leader = turn.get('batch_id', turn_id)
            if turn.get('batchable'):
                if action == 'retry':
                    if turn['status'] not in {'failed', 'interrupted'}:
                        raise APIError(409, 'Only failed or interrupted batches can be retried')
                    with agent.transaction() as state:
                        for item in state['turns']:
                            if item.get('batch_id', item['id']) == leader:
                                item.update(status='queued', attempt=item.get('attempt', 1) + 1)
                                for field in ('error', 'batch_id', 'batch_members', 'agency_kind', 'slot', 'pulseId'):
                                    item.pop(field, None)
                elif action == 'cancel':
                    if turn['status'] in {'done', 'output_pending'}:
                        raise APIError(409, 'Completed input cannot be cancelled')
                    runner = host.agencies.active_runner(agid, leader)
                    if runner:
                        runner.cancel_event.set()
                    else:
                        with agent.transaction() as state:
                            for item in state['turns']:
                                if item.get('batch_id', item['id']) == leader:
                                    item['status'] = 'cancelled'
                else:
                    raise APIError(404, 'Unknown turn action')
            elif action == 'retry':
                agent.runner.retry(turn_id)
                host.execution.queue.put(agid)
            elif action == 'cancel':
                agent.runner.cancel(turn_id)
            else:
                raise APIError(404, 'Unknown turn action')
            host.projection.sync(agent)
            host.delegation.reconcile(agid)
            return {"id": turn_id, "status": next(j["status"] for j in agent.state["turns"] if j["id"] == turn_id)}

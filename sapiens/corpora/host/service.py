"""One local host, parallel Sapi runners, and recoverable UI projections."""
from pathlib import Path
from uuid import uuid4
from time import monotonic
import asyncio
import fcntl
import json
import logging
import os
import queue
import re
import secrets
import threading

from sapiens.corpora.sapis.attachments import attachment_prompt, resolve_attachments
from sapiens.corpora.sapis.registry import Registry
from sapiens.corpora.sapis.retirement import Lifecycle
from sapiens.corpora.host.agency import ChatAgencies
from sapiens.corpora.host.routines import ScheduledRoutines
from sapiens.corpora.host.pulsation import SystemPulse
from sapiens.corpora.host.commands import Orchestration
from sapiens.corpora.host.delegation import Delegation
from sapiens.corpora.host.groups import Groups
from sapiens.paths import ROOT
from sapiens.prompts import prompt
from sapiens.corpora.sapis.notes import Notes
from sapiens.corpora.sapis.conversations import Config, Conversation, computer_manifest
from sapiens.runtime.codex import CodexFactory
from sapiens.runtime.settings import codex_binary, execution_settings
from sapiens.runtime.turns import TurnRunner
from sapiens.computer.focus import ForegroundReturn
from sapiens.files import atomic_bytes
from sapiens.corpora.host.database import Store, now
from sapiens.validation import APIError, sapi_name, text_field
from sapiens.corpora.browser import Workspace


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


class Service:
    def __init__(self, data_dir, *, factory_builder=None, start_worker=True, max_parallel_agents=4, pulse_clock=monotonic):
        if type(max_parallel_agents) is not int or not 1 <= max_parallel_agents <= 32:
            raise ValueError("max_parallel_agents must be between 1 and 32")
        self.root = Path(data_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._file_lock = (self.root / "host.lock").open("a")
        try:
            fcntl.flock(self._file_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._file_lock.close()
            raise RuntimeError("Another Sapiens4 server is using this data directory") from None
        self.store = Store(self.root / "corpora.sqlite3")
        self.workspace = Workspace(self)
        # Repair old repeated default faces once; the resulting avatars persist.
        used = set()
        for row in self.store.agents():
            if row["face"] in used:
                row.update(random_avatar(used))
                self.store.update_avatar(row["id"], row)
            used.add(row["face"])
        self.binary = ROOT / "blindly4/.build/release/blindly4"
        self.factory_builder = factory_builder
        self._agents = {}
        self._revisions = {}
        self._lock = threading.RLock()
        self._queue = queue.Queue()
        self._stopping = threading.Event()
        self._active = None
        self._computer_turn = None
        self._execution = threading.local()
        self.max_parallel_agents = max_parallel_agents
        self._runners = {}
        self.orchestration = Orchestration(self)
        self.lifecycle = Lifecycle(self)
        self.registry = Registry(self)
        self.worker = None
        self.delegation = Delegation(self)
        self.groups = Groups(self)
        self.agencies = ChatAgencies(self)
        self.routines = ScheduledRoutines(self)
        self.pulse = SystemPulse(self.store, self._on_pulse, clock=pulse_clock)
        if not self.store.agents():
            self.create_agent({"name": "SapiTheMain", "role": "Head of Corpora"})
        for row in self.store.agents():
            agent = self._agent(row["id"])
            self.agencies.recover(agent)
            self._sync(agent)
            # Public run() recovers running turns to interrupted without replaying.
            # Only previously queued, never-started work is admitted automatically.
            if not self.lifecycle.retired(agent) and any(j["status"] in {"queued", "running"} for j in agent.state["turns"]):
                self._queue.put(row["id"])
        self.registry.repair()
        self.delegation.reconcile()
        self.delegation.dispatch_pending()
        self.groups.chat.reconcile()
        self.groups.chat.dispatch()
        self.store.events.record(self.registry.main, 'corpora', 'system.started', {}, actor='system')
        if start_worker:
            self.start()

    def start(self):
        self.pulse.start()
        if self.worker is None:
            self.worker = threading.Thread(target=self._work, name="sapiens-runner", daemon=True)
            self.worker.start()

    def _agent(self, agid):
        if agid not in self._agents:
            row = next((a for a in self.store.agents() if a["id"] == agid), None)
            if row is None:
                raise APIError(404, "Unknown Sapi")
            workdir = self.root / "workspaces" / agid
            workdir.mkdir(parents=True, exist_ok=True)

            factory = (self.factory_builder(agid) if self.factory_builder else
                       CodexFactory(workdir=workdir))
            Notes(workdir).ensure(row['name'], row['role'])
            agent = Conversation(agid=agid, root=self.root / "agentpy")
            if agid not in self.registry.directory():
                self.registry.register(agid)
            complete = None
            if not self.factory_builder:
                complete = lambda llm, text: complete_with_computer(
                    llm, text, lambda restore: self.release_computer(agid, restore))
            agent.runner = TurnRunner(store=agent, context=agent.context, config=Config(),
                                      factory=factory, complete=complete,
                                      execute=lambda runner, turn, snapshot, result: (self.groups.chat if (turn.get("origin") or {}).get("group") else self.delegation).run(agid, runner, turn, snapshot, result))
            if not self.factory_builder:
                factory.execution = lambda: execution_settings(agent.root)
            self._agents[agid] = agent
            self._manifests(agent, row)
        return self._agents[agid]

    def _manifests(self, agent, row):
        agent.set_manifest("identity", prompt('identity', name=row['name'], role=row['role'], face=row['face']))
        agent.set_manifest("computer-use", computer_manifest(self.binary))

    def acquire_computer(self, agid):
        with self._lock:
            if not self._active_turn(agid):
                raise APIError(409, "Computer access requires a running Sapi turn")
            if self._active not in (None, agid):
                raise APIError(409, "Shared computer is busy with another Sapi. Continue non-UI work or report the blocker; do not retry in a loop.")
            turn_id = self._active_turn(agid)
            if self._computer_turn not in (None, turn_id):
                raise APIError(409, "Shared computer is busy with another AgencyRun")
            self._active = agid
            self._computer_turn = turn_id
            return {"owner": agid}

    def release_computer(self, agid, restore=lambda: None, *, turn_id=None):
        # Keep ownership while restoring focus; another Sapi must not begin UI
        # work between the last action and the return to CORPORA.
        with self._lock:
            turn_id = turn_id or getattr(self._execution, 'turn', None)
            if self._active != agid or (turn_id and self._computer_turn != turn_id):
                return None
        try:
            return restore()
        finally:
            with self._lock:
                if self._active == agid:
                    self._active = None
                    self._computer_turn = None

    def _active_turn(self, agid):
        agent = self._agents.get(agid)
        specific = getattr(self._execution, 'turn', None)
        if agent and specific:
            return next((t['id'] for t in agent.state['turns'] if t['id'] == specific and t['status'] == 'running'), None)
        if agent:
            return next((j["id"] for j in agent.state["turns"] if j["status"] == "running"), None)
        return None

    def _sync(self, agent):
        snapshot = agent.state
        if self._revisions.get(agent.agid) == snapshot["revision"]:
            return
        outputs = {m["turn"]: m["content"] for m in snapshot["chat"] if m.get("turn") and m["role"] == "agent"}
        for turn in snapshot["turns"]:
            if turn["status"] == "done" and turn["id"] not in outputs and turn.get("batch_id", turn["id"]) == turn["id"]:
                try:
                    outputs[turn["id"]] = agent.result(turn["id"])
                except FileNotFoundError:
                    pass  # An explicitly pruned archive need not block projection.
        self.store.project(agent.agid, snapshot, outputs)
        self._revisions[agent.agid] = snapshot["revision"]

    def create_agent(self, data):
        name, role = sapi_name(data), text_field(data, "role", 60)
        color = data.get("color", "#d8e5f4")
        if not isinstance(color, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise APIError(400, "color must be a six-digit hex color")
        face = data.get("face", "◠‿◠")
        if not isinstance(face, str) or not 1 <= len(face) <= 24:
            raise APIError(400, "face must contain 1–24 characters")
        if data.get("kind", "sapi") != "sapi":
            raise APIError(400, "Use /api/groups to create a Group")
        with self._lock:
            appearance = random_avatar({a["face"] for a in self.store.agents()})
            if "face" in data and face not in {a["face"] for a in self.store.agents()}:
                appearance["face"] = face
            if "color" in data:
                appearance["color"] = color
            row = dict(id="sapi_" + uuid4().hex[:12], name=name, role=role,
                       **appearance, created=now())
            parent = self.registry.validate(row["id"], data.get("manager"))
            self.store.add_agent(row)
            self.registry.register(row["id"], parent=parent)
            agent = self._agent(row["id"])
            self.orchestration.settings(agent)
            self.store.events.record(row['id'], row['id'], 'sapi.created', dict(row, manager=parent))
            return row

    def update_agent(self, agid, data):
        if set(data) - {"name", "role", "manager", "execution"}:
            raise APIError(400, "Unknown or inactive setting")
        policy = data.get('execution')
        if 'execution' in data and (not isinstance(policy, dict) or set(policy) != {'mode'}
                or policy['mode'] not in ('normal','deep')):
            raise APIError(400, 'Choose Normal or Deep work; call timeouts are managed globally')
        row = {"name": sapi_name(data), "role": text_field(data, "role", 60)}
        with self._lock:
            agent = self._agent(agid)
            self.lifecycle.require_active(agent)
            if any(j["status"] in {"queued", "running"} for j in agent.state["turns"]):
                raise APIError(409, "Wait for this Sapi's current turn before changing its identity")
            if "manager" in data:
                parent = self.registry.validate(agid, data["manager"])
                self.registry.assign(agent, parent)
            if policy is not None:
                atomic_bytes(agent.root / 'run-settings.json', json.dumps(policy).encode())
            self.store.update_agent(agid, row)
            self.store.events.record(agid, agid, 'sapi.updated', data)
            self._manifests(agent, next(a for a in self.store.agents() if a['id'] == agid))
        return {"id": agid, **row}

    def submit(self, agid, data):
        raw_text = data.get("text", "")
        if not isinstance(raw_text, str) or len(raw_text) > 16000:
            raise APIError(400, "Message must be text, at most 16000 characters")
        text = raw_text.strip()
        attachments = resolve_attachments(self, agid, data.get("attachments", []))
        if not text and not attachments:
            raise APIError(400, "Write a message or attach a file")
        message = text + attachment_prompt(attachments)
        flow = data.get("flow", "chat")
        if flow not in ("chat", "computer"):
            raise APIError(400, "Choose chat or computer")
        if not self.factory_builder and not codex_binary():
            raise APIError(503, "Codex CLI is missing. Install it and run codex login.")
        if flow == "computer" and not self.factory_builder and not os.access(self.binary, os.X_OK):
            raise APIError(503, "Blindly4 is not built. Run ./start.sh to build it.")
        with self._lock:
            if self._stopping.is_set():
                raise APIError(503, "Server is shutting down")
            agent = self._agent(agid)
            # A failed attempt remains reviewable; a new message is not a retry.
            self.lifecycle.require_active(agent)
            routine = self.routines.command(agid, text, attachments)
            if routine:
                return self.routines.acknowledge(agent, text, routine)
            if data.get('workload'):
                turn = self.delegation.clarify(agid, data['workload'], message)
            else:
                turn = agent.runner.submit(flow, message, batchable=True)
            self.store.message(turn, text, attachments)
            self._sync(agent)
            self._queue.put(agid)
            return {"id": turn, "agent": agid, "status": "queued", "flow": flow}

    def turn_action(self, agid, turn_id, action):
        with self._lock:
            agent = self._agent(agid)
            self.lifecycle.require_active(agent)
            turns = agent.state["turns"]
            turn = next((j for j in turns if j["id"] == turn_id), None)
            if turn is None:
                raise APIError(404, "Unknown active turn")
            work, call = self.delegation.find(turn_id)
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
                    runner = self.agencies.active_runner(agid, leader)
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
                self._queue.put(agid)
            elif action == 'cancel':
                agent.runner.cancel(turn_id)
            else:
                raise APIError(404, 'Unknown turn action')
            self._sync(agent)
            self.delegation.reconcile(agid)
            return {"id": turn_id, "status": next(j["status"] for j in agent.state["turns"] if j["id"] == turn_id)}

    def snapshot(self, agid=None):
        with self._lock:
            if agid:
                self._agent(agid)
            for agent in self._agents.values():
                self._sync(agent)
            self.groups.chat.reconcile()
            snapshot = self.store.snapshot(agid)
            snapshot["groups"] = self.groups.snapshot()
            snapshot["routines"] = self.store.routines()
            snapshot["creation_template"] = prompt("creation-request").strip()
            group_turns = {r["id"]: g["id"] for g in snapshot["groups"] for r in g["requests"]}
            for turn in snapshot["turns"]:
                if turn["id"] in group_turns:
                    turn["group"] = group_turns[turn["id"]]
            for row in snapshot['agents']:
                row['retired'] = self.lifecycle.retired(self._agent(row['id']))
            snapshot["computer"] = {"owner": self._active,
                                    "built": os.access(self.binary, os.X_OK)}
            snapshot['pulses'] = self.store.pulse_calls(agid)
            snapshot['events'] = self.store.events.snapshot(agid)
            snapshot['pulse'] = dict(id=self.pulse.identity, running=self.pulse.running, numbers=dict(self.pulse.numbers))
            snapshot["provider"] = "codex"
            snapshot['activity'] = {a.agid: {**getattr(a.runner.active_llm, 'activity', {}),
                'turn': self._active_turn(a.agid), 'stopping': a.runner.cancel_event.is_set()}
                for a in self._agents.values() if self._active_turn(a.agid)}
            snapshot['run_activity'] = {}
            for (owner, kind, slot), (runner, _, batch_id) in self.agencies.slots.items():
                activity = dict(getattr(runner.active_llm, 'activity', {}), turn=batch_id,
                                stopping=runner.cancel_event.is_set(), agencyKind=kind, slot=slot)
                snapshot['run_activity'][batch_id] = activity
                snapshot['activity'][owner] = activity
            snapshot["main_agent_id"] = self.registry.main
            workloads = self.store.workloads()
            snapshot["workloads"] = self.delegation.summaries(workloads)
            origins = {}
            for work in workloads:
                calls = {c['callId']: c for c in work['calls']}
                for call in calls.values():
                    if call['causedBy'] and call.get('activation') != 'RequestClarified':
                        origins[call['callId']] = {'caller': calls[call['causedBy']]['addressedTo'],
                                                   'parentCall': call['causedBy']}
            for turn in snapshot['turns']:
                if turn['id'] in origins:
                    turn['origin'] = {**(turn.get('origin') or {}), **origins[turn['id']]}
            snapshot["attachment_drafts"] = {
                agid: [a for a in self.store.attachments(agid) if a["id"] in ids]
                for agid, ids in snapshot["preferences"].get("attachment_drafts", {}).items()}

            snapshot["orchestration"] = {
                a.agid: {"manager": self.registry.directory().get(a.agid, {}).get("parent"),
                         "execution": execution_settings(a.root),
                         "notes": Notes(self.workspace.root(a)).metadata()}
                for a in self._agents.values()}
            return snapshot


    def save_preferences(self, data):
        # Browser state never gets authority over runtime turns, agents or computer ownership.
        if set(data) - {"selected", "panel", "scope", "groupView", "panes", "drafts", "attachment_drafts"}:
            raise APIError(400, "Unknown preference field")
        for field in ("panes", "drafts", "attachment_drafts"):
            if field in data and not isinstance(data[field], dict):
                raise APIError(400, f"{field} must be an object")
        if "selected" in data and data["selected"] not in {a["id"] for a in self.store.agents()} | {g["id"] for g in self.store.groups()}:
            raise APIError(400, "Unknown selected Sapi")
        if data.get("groupView") is not None and data["groupView"] not in {g["id"] for g in self.store.groups()}:
            raise APIError(400, "Unknown Group view")
        if data.get("panel", "chat") not in {"chat", "tasks", "notes", "work", "updates"}:
            raise APIError(400, "Unknown panel")
        if data.get("scope", "all") not in {"all", "sapis", "groups"}:
            raise APIError(400, "Unknown view")
        if any(k not in {"sidebar", "chat", "workspace"} or type(v) is not bool
               for k, v in data.get("panes", {}).items()):
            raise APIError(400, "Invalid panel visibility")
        for key, value in data.get("drafts", {}).items():
            if not isinstance(value, str) or len(value) > 16000:
                raise APIError(400, "Invalid draft")
        for agid, ids in data.get("attachment_drafts", {}).items():
            resolve_attachments(self, agid, ids, check_files=False)
        with self._lock:
            current = self.store.read_preferences()
            current.update(data)
            self.store.preferences(current)
            return {"saved": True, "preferences": current}


    def _run_queued(self, agid, *, legacy_only=False):
        with self._lock:
            agent = self._agent(agid)
            if legacy_only and (not self.pulse.running or self._stopping.is_set()):
                return
            if self.lifecycle.retired(agent) or not any(
                    j['status'] in {'queued', 'running'} for j in agent.state['turns']):
                return
            self.orchestration.prepare(agent)
        with self.store.events.context(agid, 'chatInput'):
            asyncio.run(agent.runner.run(legacy_only=legacy_only))

    def _dispatch(self, agid, tick=None):
        with self._lock:
            if self.lifecycle.retired(self._agent(agid)):
                return False
            owners = {key[0] for key in self.agencies.slots} | set(self._runners)
            if (not self.pulse.running or self._stopping.is_set() or agid in owners
                    or len(owners) >= self.max_parallel_agents):
                return False
            self._agent(agid).runner.cancel_event.clear()
            def run():
                try:
                    self._run_queued(agid, legacy_only=True)
                except Exception:
                    logging.exception("Sapi runner failed: %s", agid)
                finally:
                    try:
                        self.release_computer(agid)
                        with self._lock:
                            self._sync(self._agent(agid))
                    finally:
                        with self._lock:
                            self._runners.pop(agid, None)
                            self.delegation.reconcile(agid)
                            self.delegation.dispatch_pending()
                            self.groups.chat.reconcile()
                            self.groups.chat.dispatch()
            thread = threading.Thread(target=run, name=f'sapiens-{agid}', daemon=True)
            self._runners[agid] = thread
            if tick:
                self.store.record_pulse_call(tick, agid, 'chatInput', 1,
                    groups={t['origin']['group'] for t in self._agent(agid).state['turns']
                            if t['status'] in {'queued', 'running'} and (t.get('origin') or {}).get('group')})
            thread.start()
            return thread

    def _on_pulse(self, tick):
        with self._lock:
            if not self.pulse.running or self._stopping.is_set():
                return
            self.routines.dispatch(tick)
            self.agencies.dispatch(tick)
            if tick['frequency'] == 'bpm60' and tick['num'] % self.agencies.policies['chatInput'].every == 0:
                self.delegation.dispatch_pending()
                self.groups.chat.reconcile()
                self.groups.chat.dispatch()
                for agent in list(self._agents.values()):
                    if any(t['status'] == 'queued' and not t.get('batchable') for t in agent.state['turns']):
                        self._dispatch(agent.agid, tick)

    def stop_pulse(self):
        with self._lock:
            self.pulse.stop()
            self.agencies.cancel_all()
            for agid in self._runners:
                self._agent(agid).runner.cancel_event.set()

    def _work(self):
        while not self._stopping.wait(.05):
            try:
                with self._lock:
                    self.pulse.step()
                # Compatibility wakeups no longer start execution themselves.
                while True:
                    try:
                        self._queue.get_nowait()
                    except queue.Empty:
                        break
            except Exception:
                logging.exception('System Pulse dispatch failed')

    def close(self):
        if self._file_lock.closed:
            return
        self._stopping.set()
        self.stop_pulse()
        self._queue.put(None)
        if self.worker:
            self.worker.join()
        with self._lock:
            runners = list(self._runners.values()) + [entry[1] for entry in self.agencies.slots.values()]
        for runner in runners:
            runner.join()  # Retain host.lock until every call has finished.
        self.store.events.record(self.registry.main, 'corpora', 'system.stopped', {}, actor='system')
        fcntl.flock(self._file_lock, fcntl.LOCK_UN)
        self._file_lock.close()

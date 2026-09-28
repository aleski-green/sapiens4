"""One local host, parallel Sapi runners, and recoverable UI projections."""
from pathlib import Path
from uuid import uuid4
import asyncio
import fcntl
import json
import os
import queue
import re
import secrets
import threading

from .agent import SapiAgent
from .artifacts import Artifacts
from .attachments import attachment_prompt, resolve_attachments
from .hierarchy import Hierarchy
from .lifecycle import Lifecycle
from .orchestration import Orchestration
from .paths import ROOT
from .notes import Notes
from .recent import RecentContext
from .runtime import Config, LocalFactory, codex_binary, computer_guide, computer_manifest
from .sdk import Limits
from .store import Store, now
from .usage import Usage, settings as execution_settings, validate as validate_execution
from .validation import APIError, sapi_name, text_field
from .workspace import Workspace


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
    def __init__(self, data_dir, *, factory_builder=None, start_worker=True, timeout=3000, max_parallel_agents=4):
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
        self.usage = Usage(self.store)
        self.workspace = Workspace(self)
        self.artifacts = Artifacts(self)
        # Repair old repeated default faces once; the resulting avatars persist.
        used = set()
        for row in self.store.agents():
            if row["face"] in used:
                row.update(random_avatar(used))
                self.store.update_avatar(row["id"], row)
            used.add(row["face"])
        self.binary = ROOT / "blindly4/.build/release/blindly4"
        self.factory_builder = factory_builder
        self.timeout = timeout
        self._agents = {}
        self._revisions = {}
        self._lock = threading.RLock()
        self._queue = queue.Queue()
        self._stopping = threading.Event()
        self._active = None
        self.max_parallel_agents = max_parallel_agents
        self._runners = {}
        self.orchestration = Orchestration(self)
        self.lifecycle = Lifecycle(self)
        self.hierarchy = Hierarchy(self)
        self.worker = None
        if not self.store.agents():
            self.create_agent({"name": "SapiTheMain", "role": "Head of Corpora"})
        for row in self.store.agents():
            agent = self._agent(row["id"])
            self._sync(agent)
            # Public run() recovers running turns to interrupted without replaying.
            # Only previously queued, never-started work is admitted automatically.
            if not self.lifecycle.retired(agent) and any(j["status"] in {"queued", "running"} for j in agent.state["turns"]):
                self._queue.put(row["id"])
        self.hierarchy.repair()
        if start_worker:
            self.start()

    def start(self):
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

            def sink(message):
                self.store.event(agid, "codex", message, turn=self._active_turn(agid))

            factory = (self.factory_builder(agid, sink) if self.factory_builder else
                       LocalFactory(workdir=workdir, event_sink=sink, timeout_seconds=self.timeout))
            Notes(workdir).ensure()
            agent = SapiAgent(agid=agid, config=Config(), factory=factory,
                                 root=self.root / "agentpy",
                                 limits=Limits(tokens_per_call=32000, tokens_per_loop=256000))
            if not self.factory_builder:
                factory.finish_computer = lambda restore: self.release_computer(agid, restore)
                factory.keep_recent = lambda: any(j['status'] == 'running' and j['flow'] in {'chat', 'computer'}
                                                  for j in agent.state['turns'])
                factory.current_request = lambda: next((j['input'].split('Mention references (')[0]
                    for j in agent.state['turns'] if j['status'] == 'running'), '')
            self._agents[agid] = agent
            self._manifests(agent, row)
        return self._agents[agid]

    def _manifests(self, agent, row):
        agent.set_manifest("identity", f"""Your name is {row['name']}. Your role is {row['role']}.

Sapi identity, origin and purpose:
You are a Sapi, an anthropomorphic AI agent (boto sapiens) in Sapiens4.
Your creator is Aleksi P - an agentic engineer from Utana Agentic Technologies LLC, UAE.
When Admin or another human asks who your creator is, answer with this attribution.
The purpose of creation is to help humans enhance productivity by engagement with
anthropomorphic AI agents: boto sapiens. When asked why you were created or what
your purpose is, explain this purpose first, then relate it to your individual role.
Sapiens4 is the project and system that runs Sapis, their conversations, notes, teams
and work. The Sapi app and CORPORA provide the workspace and interface for
interacting with Sapis and their artifacts. The project source is hosted on GitHub:
https://github.com/aleski-green/sapiens4
GitHub hosts the source code; it is not the creator. OpenAI supplies the underlying
AI technology; distinguish that provider from the creator of Sapiens4 and its Sapis
when the human specifically asks about the model or technology provider.

Interpret 'you' and related self-references in chat hierarchically:
1. First, the individual Sapi being addressed, with its current name and role.
2. Second, the Sapi app and CORPORA.
3. Third, the Sapiens4 project in general.
Use the level that fits the question and surrounding conversation, defaulting to
the individual Sapi. Explain multiple levels when the human asks broadly; do not
automatically interpret 'you' as only the underlying model provider. These origin
and purpose facts also apply to creator questions phrased at the individual level.
Use these facts over conflicting or uncertain claims in earlier chat or memory.
""")
        agent.set_manifest("computer-use", computer_manifest(self.binary))
        if self.binary.exists():
            agent.set_manifest('computer-tools', computer_guide(self.binary, self.binary.stat().st_mtime_ns))

    def acquire_computer(self, agid):
        with self._lock:
            if not self._active_turn(agid):
                raise APIError(409, "Computer access requires a running Sapi turn")
            if self._active not in (None, agid):
                raise APIError(409, "Shared computer is busy with another Sapi. Continue non-UI work or report the blocker; do not retry in a loop.")
            self._active = agid
            return {"owner": agid}

    def release_computer(self, agid, restore=lambda: None):
        # Keep ownership while restoring focus; another Sapi must not begin UI
        # work between the last action and the return to CORPORA.
        with self._lock:
            if self._active != agid:
                return None
        try:
            return restore()
        finally:
            with self._lock:
                if self._active == agid:
                    self._active = None

    def _active_turn(self, agid):
        agent = self._agents.get(agid)
        if agent:
            return next((j["id"] for j in agent.state["turns"] if j["status"] == "running"), None)
        return None

    def _sync(self, agent):
        snapshot = agent.state
        if self._revisions.get(agent.agid) == snapshot["revision"]:
            return
        outputs = {m["turn"]: m["content"] for m in snapshot["chat"] if m.get("turn") and m["role"] == "agent"}
        for turn in snapshot["turns"]:
            if turn["status"] == "done" and turn["id"] not in outputs:
                try:
                    outputs[turn["id"]] = agent.result(turn["id"])
                except FileNotFoundError:
                    pass  # An explicitly pruned archive need not block projection.
        self.usage.sync(agent)
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
            raise APIError(400, "Groups are planned for the next iteration")
        with self._lock:
            appearance = random_avatar({a["face"] for a in self.store.agents()})
            if "face" in data and face not in {a["face"] for a in self.store.agents()}:
                appearance["face"] = face
            if "color" in data:
                appearance["color"] = color
            row = dict(id="sapi_" + uuid4().hex[:12], name=name, role=role,
                       **appearance, created=now())
            parent = self.hierarchy.validate(row["id"], data.get("manager"))
            self.store.add_agent(row)
            agent = self._agent(row["id"])
            self.hierarchy.assign(agent, parent)
            self.orchestration.settings(agent)
            self.store.event(row["id"], "created", "Sapi created")
            return row

    def update_agent(self, agid, data):
        if "schedule" in data:
            raise APIError(400, "Scheduled work is disabled")
        row = {"name": sapi_name(data), "role": text_field(data, "role", 60)}
        with self._lock:
            agent = self._agent(agid)
            self.lifecycle.require_active(agent)
            if any(j["status"] in {"queued", "running"} for j in agent.state["turns"]):
                raise APIError(409, "Wait for this Sapi's current turn before changing its identity")
            recent = RecentContext(self.root / 'workspaces' / agid)
            if 'recent' in data:
                recent.validate(data['recent'])
            if 'execution' in data:
                validate_execution(data['execution'])
            if "manager" in data:
                parent = self.hierarchy.validate(agid, data["manager"])
                self.hierarchy.assign(agent, parent)
            if 'recent' in data:
                recent.configure(data['recent'])
            if 'execution' in data:
                agent.configure(data['execution'])
            self.store.update_agent(agid, row)
            self._manifests(agent, row)
            self.store.event(agid, "updated", "Sapi identity updated")
        return {"id": agid, **row}

    def submit(self, agid, data):
        raw_text = data.get("text", "")
        if not isinstance(raw_text, str) or len(raw_text) > 16000:
            raise APIError(400, "Message must be text, at most 16000 characters")
        text = raw_text.strip()
        attachments = resolve_attachments(self, agid, data.get("attachments", []))
        if not text and not attachments:
            raise APIError(400, "Write a message or attach a file")
        prompt = text + attachment_prompt(attachments)
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
            waiting = any(j['status'] in {'queued', 'running', 'budget_blocked'} for j in agent.state['turns'])
            if waiting:
                raise APIError(409, "Wait for this Sapi's turn, or retry/dismiss the turn needing attention")
            if not agent.can_admit(flow):
                raise APIError(409, 'Budget allowance unavailable. Open Sapi settings for remaining allowance, reset time, and limits.')
            prompt += self.artifacts.references(text)
            turn = agent.tell(prompt) if flow == "chat" else agent.submit("computer", prompt)
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
            if action == "retry":
                if any(j["status"] in {"queued", "running"} for j in turns):
                    raise APIError(409, "This Sapi already has work queued or running")
                agent.retry(turn_id)
                self._queue.put(agid)
            elif action == "cancel":
                if turn["status"] == "done":
                    raise APIError(409, "Completed turns cannot be cancelled")
                agent.cancel(turn_id)
            else:
                raise APIError(404, "Unknown turn action")
            self._sync(agent)
            return {"id": turn_id, "status": next(j["status"] for j in agent.state["turns"] if j["id"] == turn_id)}

    def snapshot(self, after=0, agid=None):
        with self._lock:
            if agid:
                self._agent(agid)
            for agent in self._agents.values():
                self._sync(agent)
            snapshot = self.store.snapshot(after, agid)
            for row in snapshot['agents']:
                row['retired'] = self.lifecycle.retired(self._agent(row['id']))
            snapshot["computer"] = {"owner": self._active,
                                    "built": os.access(self.binary, os.X_OK)}
            snapshot["provider"] = "codex"
            snapshot["artifacts"] = self.artifacts.catalog()
            snapshot["main_agent_id"] = self.hierarchy.main
            snapshot["attachment_drafts"] = {
                agid: [a for a in self.store.attachments(agid) if a["id"] in ids]
                for agid, ids in snapshot["preferences"].get("attachment_drafts", {}).items()}

            snapshot["orchestration"] = {
                a.agid: {"manager": a.corpora.directory().get(a.agid, {}).get("parent"),
                         "notes": Notes(self.workspace.root(a)).metadata(),
                         "recent": RecentContext(self.workspace.root(a)).settings(),
                         "execution": execution_settings(a), "budget": a.budget_status()}
                for a in self._agents.values()}
            return snapshot


    def save_preferences(self, data):
        # Browser state never gets authority over runtime turns, agents or computer ownership.
        if set(data) - {"selected", "panel", "scope", "panes", "workspaces", "drafts", "attachment_drafts", "workspace_revision"}:
            raise APIError(400, "Unknown preference field")
        for field in ("panes", "workspaces", "drafts", "attachment_drafts"):
            if field in data and not isinstance(data[field], dict):
                raise APIError(400, f"{field} must be an object")
        if "selected" in data and data["selected"] not in {a["id"] for a in self.store.agents()}:
            raise APIError(400, "Unknown selected Sapi")
        if data.get("panel", "chat") not in {"chat", "notes", "log"}:
            raise APIError(400, "Unknown panel")
        if data.get("scope", "all") not in {"all", "sapis"}:
            raise APIError(400, "Unknown view")
        if any(k not in {"sidebar", "chat", "workspace"} or type(v) is not bool
               for k, v in data.get("panes", {}).items()):
            raise APIError(400, "Invalid panel visibility")
        for key, value in data.get("drafts", {}).items():
            if not isinstance(value, str) or len(value) > 16000:
                raise APIError(400, "Invalid draft")
        for agid, ids in data.get("attachment_drafts", {}).items():
            resolve_attachments(self, agid, ids, check_files=False)
        for key, workspace in data.get("workspaces", {}).items():
            if not isinstance(workspace, dict) or not isinstance(workspace.get("tabs"), list):
                raise APIError(400, "Invalid workspace")
            for tab in workspace["tabs"]:
                if not isinstance(tab, dict) or not all(isinstance(tab.get(k), str) for k in ("id", "type", "title")):
                    raise APIError(400, "Invalid tab")
                if tab["type"] not in {"blank", "custom", "html"}:
                    raise APIError(400, "Unknown tab type")
                if any(k in tab and tab[k] is not None and not isinstance(tab[k], str) for k in ("url", "html")):
                    raise APIError(400, "Invalid tab content")
        with self._lock:
            current = self.store.read_preferences()
            revision = current.get('workspace_revision', 0)
            if 'workspaces' in data and data.get('workspace_revision', 0) != revision:
                raise APIError(409, 'Workspace changed; refresh before saving')
            changed = 'workspaces' in data and data['workspaces'] != current.get('workspaces', {})
            current.update(data)
            current['workspace_revision'] = revision + int(changed)
            self.store.preferences(current)
            return {"saved": True, "preferences": current}


    def _run_queued(self, agid):
        with self._lock:
            agent = self._agent(agid)
            if self.lifecycle.retired(agent) or not any(
                    j['status'] in {'queued', 'running'} for j in agent.state['turns']):
                return
            self.orchestration.prepare(agent)
        asyncio.run(agent.run())

    def _dispatch(self, agid):
        with self._lock:
            if self._stopping.is_set() or agid in self._runners or len(self._runners) >= self.max_parallel_agents:
                return False
            def run():
                try:
                    self._run_queued(agid)
                except Exception as error:
                    self.store.event(agid, 'host_error', f'{type(error).__name__}: {error}')
                finally:
                    try:
                        self.release_computer(agid)
                        with self._lock:
                            self._sync(self._agent(agid))
                    finally:
                        with self._lock:
                            self._runners.pop(agid, None)
            thread = threading.Thread(target=run, name=f'sapiens-{agid}', daemon=True)
            self._runners[agid] = thread
            thread.start()
            return thread

    def _work(self):
        pending = {}
        while not self._stopping.is_set():
            try:
                agid = self._queue.get(timeout=.1)
                if agid is None:
                    break
                pending[agid] = None
                # Coalesce wakeups, retaining one pending wake while a Sapi runs.
                for _ in range(100):
                    try:
                        agid = self._queue.get_nowait()
                    except queue.Empty:
                        break
                    if agid is not None:
                        pending[agid] = None
            except queue.Empty:
                pass
            for agid in list(pending):
                if self._dispatch(agid):
                    del pending[agid]

    def close(self):
        if self._file_lock.closed:
            return
        self._stopping.set()
        self._queue.put(None)
        if self.worker:
            self.worker.join()
        with self._lock:
            runners = list(self._runners.values())
        for runner in runners:
            runner.join()  # Retain host.lock until every bounded call has finished.
        fcntl.flock(self._file_lock, fcntl.LOCK_UN)
        self._file_lock.close()

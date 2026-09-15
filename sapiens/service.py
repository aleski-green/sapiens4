"""One local host, serialized execution, and recoverable UI projections."""
import asyncio
import secrets
import fcntl
import os
from pathlib import Path
import queue
import re
import threading
from uuid import uuid4

from .runtime import AgentPy, Config, Limits, LocalFactory, ROOT, SDK, codex_binary, computer_manifest
from .store import Store, now
from .orchestration import Orchestration, utcnow
from .hierarchy import Hierarchy
from .work import Work
from .tasks import Tasks


class APIError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def text_field(data, field, maximum):
    value = data.get(field)
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise APIError(400, f"{field} must be nonempty text, at most {maximum} characters")
    return value.strip()


def sapi_name(data):
    value = text_field(data, "name", 24)
    if value != data["name"] or not re.fullmatch(r"[A-Z][A-Za-z0-9_.:#+|()&$^\-]*", value):
        raise APIError(400, "Name must start with A–Z; use letters, numbers, or - _ . : # + | ( ) & $ ^ (no spaces)")
    return value


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
    def __init__(self, data_dir, *, factory_builder=None, start_worker=True, timeout=300):
        self.root = Path(data_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._file_lock = (self.root / "host.lock").open("a")
        try:
            fcntl.flock(self._file_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._file_lock.close()
            raise RuntimeError("Another Sapiens4 server is using this data directory") from None
        self.store = Store(self.root / "corpora.sqlite3")
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
        self._background = set()
        self.orchestration = Orchestration(self)
        self.hierarchy = Hierarchy(self)
        self.work = Work(self)
        self.tasks = Tasks(self)
        self.worker = None
        if not self.store.agents():
            self.create_agent({"name": "Sapi", "role": "Personal assistant"})
        for row in self.store.agents():
            agent = self._agent(row["id"])
            self._sync(agent)
            # Public run() recovers running jobs to interrupted without replaying.
            # Only previously queued, never-started work is admitted automatically.
            if any(j["status"] in {"queued", "running"} for j in agent.state["jobs"]):
                self._queue.put(row["id"])
        self.hierarchy.repair()
        self.tasks.repair()
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
                self.store.event(agid, "codex", message, job=self._active_job(agid))

            factory = (self.factory_builder(agid, sink) if self.factory_builder else
                       LocalFactory(workdir=workdir, event_sink=sink, timeout_seconds=self.timeout))
            agent = AgentPy.open(agid=agid, config=Config(), factory=factory,
                                 root=self.root / "agentpy", source=SDK,
                                 limits=Limits(parallel_jobs=1, tokens_per_call=32000, tokens_per_loop=256000))
            if not self.factory_builder:
                factory.keep_recent = lambda: any(j['status'] == 'running' and j['flow'] in {'chat', 'computer'}
                                                  for j in agent.state['jobs'])
            self._agents[agid] = agent
            self._manifests(agent, row)
        return self._agents[agid]

    def _manifests(self, agent, row):
        agent.set_manifest("identity", f"Your name is {row['name']}. Your role is {row['role']}.")
        agent.set_manifest("computer-use", computer_manifest(self.binary))

    def _active_job(self, agid):
        agent = self._agents.get(agid)
        if agent:
            return next((j["id"] for j in agent.state["jobs"] if j["status"] == "running"), None)
        return None

    def _sync(self, agent):
        snapshot = agent.state
        if self._revisions.get(agent.agid) == snapshot["revision"]:
            return
        outputs = {m["job"]: m["content"] for m in snapshot["chat"] + snapshot["notes"] if m.get("job")}
        for job in snapshot["jobs"]:
            if job["status"] == "done" and job["id"] not in outputs:
                try:
                    outputs[job["id"]] = agent.result(job["id"])
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
        row = {"name": sapi_name(data), "role": text_field(data, "role", 60)}
        with self._lock:
            agent = self._agent(agid)
            if any(j["status"] in {"queued", "running"} for j in agent.state["jobs"]):
                raise APIError(409, "Wait for this Sapi's current job before changing its identity")
            schedule = None
            if "schedule" in data:
                schedule = self.orchestration.validate_schedule(agent, data["schedule"])
            if "manager" in data:
                parent = self.hierarchy.validate(agid, data["manager"])
                self.hierarchy.assign(agent, parent)
            if schedule is not None:
                self.orchestration.save(agent, schedule)
            self.store.update_agent(agid, row)
            self._manifests(agent, row)
            self.store.event(agid, "updated", "Sapi identity updated")
        return {"id": agid, **row}

    def submit(self, agid, data):
        raw_text = data.get("text", "")
        if not isinstance(raw_text, str) or len(raw_text) > 16000:
            raise APIError(400, "Message must be text, at most 16000 characters")
        text = raw_text.strip()
        from .attachments import resolve_attachments, attachment_prompt
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
            if agid in self._background or any(j["status"] not in {"done", "cancelled"} for j in agent.state["jobs"]):
                raise APIError(409, "Wait for this Sapi's job, or retry/dismiss the job needing attention")
            prompt += self.tasks.references(text)
            job = agent.tell(prompt) if flow == "chat" else agent.submit("computer", prompt)
            self.store.message(job, text, attachments)
            self._sync(agent)
            self._queue.put(agid)
            return {"id": job, "agent": agid, "status": "queued", "flow": flow}

    def job_action(self, agid, job_id, action):
        with self._lock:
            agent = self._agent(agid)
            jobs = agent.state["jobs"]
            job = next((j for j in jobs if j["id"] == job_id), None)
            if job is None:
                raise APIError(404, "Unknown active job")
            if action == "retry":
                if any(j["status"] in {"queued", "running"} for j in jobs):
                    raise APIError(409, "This Sapi already has work queued or running")
                agent.retry(job_id)
                self._queue.put(agid)
            elif action == "cancel":
                if job["status"] == "done":
                    raise APIError(409, "Completed jobs cannot be cancelled")
                agent.cancel(job_id)
            else:
                raise APIError(404, "Unknown job action")
            self._sync(agent)
            return {"id": job_id, "status": next(j["status"] for j in agent.state["jobs"] if j["id"] == job_id)}

    def snapshot(self, after=0, agid=None):
        with self._lock:
            if agid:
                self._agent(agid)
            for agent in self._agents.values():
                self._sync(agent)
            snapshot = self.store.snapshot(after, agid)
            snapshot["computer"] = {"owner": self._active,
                                    "built": os.access(self.binary, os.X_OK)}
            snapshot["provider"] = "codex"
            snapshot["task_assignments"] = self.tasks.notices()
            snapshot["main_agent_id"] = self.hierarchy.main
            snapshot["attachment_drafts"] = {
                agid: [a for a in self.store.attachments(agid) if a["id"] in ids]
                for agid, ids in snapshot["preferences"].get("attachment_drafts", {}).items()}

            snapshot["orchestration"] = {
                a.agid: {"schedule": self.orchestration.settings(a), "tasks": a.state["tasks"],
                         "manager": a.corpora.directory().get(a.agid, {}).get("parent"),
                         "memory_entries": len(a.memx),
                         **self.work.snapshot(a, snapshot["jobs"])} for a in self._agents.values()}
            return snapshot

    def save_preferences(self, data):
        # Browser state never gets authority over runtime jobs, agents or computer ownership.
        if set(data) - {"selected", "panel", "scope", "panes", "workspaces", "drafts", "attachment_drafts", "work_views"}:
            raise APIError(400, "Unknown preference field")
        for field in ("panes", "workspaces", "drafts", "attachment_drafts", "work_views"):
            if field in data and not isinstance(data[field], dict):
                raise APIError(400, f"{field} must be an object")
        if "selected" in data and data["selected"] not in {a["id"] for a in self.store.agents()}:
            raise APIError(400, "Unknown selected Sapi")
        if data.get("panel", "chat") not in {"chat", "tasks", "cron", "log"}:
            raise APIError(400, "Unknown panel")
        if data.get("scope", "all") not in {"all", "sapis"}:
            raise APIError(400, "Unknown view")
        if any(k not in {"sidebar", "chat", "workspace"} or type(v) is not bool
               for k, v in data.get("panes", {}).items()):
            raise APIError(400, "Invalid panel visibility")
        if any(k not in {"tasks", "cron", "log"} or not isinstance(v, str) or v not in {"ongoing", "past"}
               for k, v in data.get("work_views", {}).items()):
            raise APIError(400, "Invalid work view")
        for key, value in data.get("drafts", {}).items():
            if not isinstance(value, str) or len(value) > 16000:
                raise APIError(400, "Invalid draft")
        from .attachments import resolve_attachments
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
        self.store.preferences(data)
        return {"saved": True}

    def scheduled(self, instant=None):
        """One serialized scheduling pass, also callable with a clock in tests."""
        instant = instant or utcnow()
        for row in self.store.agents():
            if self._stopping.is_set():
                return
            background = False
            try:
                with self._lock:
                    agent = self._agent(row["id"])
                    if any(j["status"] not in {"done", "cancelled"} for j in agent.state["jobs"]):
                        continue  # Stopped work requires explicit retry/dismiss.
                    settings = self.orchestration.settings(agent)
                    due = self.orchestration.due(agent, instant)
                    recurring = self.work.due(agent, instant)
                    if not due and not settings["consolidate_requested"] and not recurring:
                        continue
                    self._background.add(agent.agid)
                    background = True
                    self.orchestration.prepare(agent)
                    if settings["consolidate_requested"]:
                        agent.submit("learning", key=f"manual-learning:{agent.state['chat_revision']}")
                        settings["consolidate_requested"] = False
                        self.orchestration.save(agent, settings)
                        due = False
                    elif not due and recurring:
                        self.work.admit(agent, recurring, instant)
                        self._active = agent.agid
                    if due:
                        self.orchestration.checked(agent, instant)
                if due:
                    asyncio.run(agent.tick(now=instant, force=True))
                else:
                    asyncio.run(agent.run())
            except Exception as error:
                self.store.event(row["id"], "host_error", f"{type(error).__name__}: {error}")
            finally:
                if background:
                    with self._lock:
                        self._active = None
                        self._background.discard(agent.agid)
                        self._sync(agent)
            if self._stopping.is_set():
                return

    def _work(self):
        while not self._stopping.is_set():
            try:
                agid = self._queue.get(timeout=1)
            except queue.Empty:
                self.scheduled()
                continue
            if agid is None:
                return
            with self._lock:
                agent = self._agent(agid)
                self.orchestration.prepare(agent)
                jobs = agent.state["jobs"]
                self._active = agid if any(j["flow"] in {"chat", "computer", "scheduled"} and j["status"] == "queued" for j in jobs) else None
            try:
                asyncio.run(agent.run())
            except Exception as error:
                self.store.event(agid, "host_error", f"{type(error).__name__}: {error}")
            finally:
                with self._lock:
                    self._active = None
                    self._sync(agent)
            self.scheduled()

    def close(self):
        self._stopping.set()
        self._queue.put(None)
        if self.worker:
            self.worker.join()  # Keep the host lock until bounded Codex calls have finished.
        fcntl.flock(self._file_lock, fcntl.LOCK_UN)
        self._file_lock.close()

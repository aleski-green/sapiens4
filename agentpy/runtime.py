"""Persistent agent: durable jobs, concurrent workers, one transactional writer."""
from __future__ import annotations

import asyncio
from copy import deepcopy
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone
import json
import hashlib
from pathlib import Path
from uuid import uuid4
from zoneinfo import ZoneInfo

from .memory import ListMemory
from .corpora import Corpora
from .interfaces import LLMSpec
from .lifecycle import Limits, MorphPolicy, Outcome, Python, Schedule, Wake
from .morphos import Morphos
from .storage import StateStore, encode, file_lock, safe_child


def utcnow():
    return datetime.now(timezone.utc)


class PersistentAgent:
    """No scheduler or LLM is started by opening an agent."""

    def __init__(self, *, config, factory, agid=None, root=".agentpy", corpora=None,
                 source=".", limits=None, morph_policy=None):
        self.agid = agid or f"ag_{uuid4().hex[:12]}"
        self.root = safe_child(Path(root).resolve() / "agents", self.agid)
        self.base_config = config
        self.config = config
        self.factory = factory
        self.limits = limits or Limits()
        self.store = StateStore(self.root, self.limits)
        self.corpora = corpora or Corpora(Path(root).resolve() / "corpora")
        self.morphos = Morphos(self.root / "morphos", source, morph_policy or MorphPolicy())
        self._loaded_version = None
        with file_lock(self.root / ".state.lock"):
            if not self.store.path.exists():
                self.store.write(dict(
                    schema_version=1, agid=self.agid, revision=0, mem_revision=0,
                    limits=asdict(self.limits), budget_calendar=asdict(getattr(config, "schedule", Schedule())),
                    memx=[], chat=[], chat_revision=0, learned_revision=0, notes=[],
                    tasks=[], projects=[], jobs=[], outbox=[], events=[], event_sequence=0,
                    last_output=None, last_circa=None, next_awake=None,
                    morphos_version=None, previous_morphos=None, budgets={},
                ))
            if self.store.read()["agid"] != self.agid:
                raise ValueError("Agent ID does not match saved state")
        saved = self.store.read()
        self.limits = limits or Limits(**saved["limits"])
        self.store.limits = self.limits
        self.budget_calendar = Schedule(**saved["budget_calendar"])
        if self.agid not in self.corpora.directory():
            self.corpora.register(self.agid)
        self._load_body(self.store.read())

    def _load_body(self, state):
        version = state["morphos_version"]
        if version != self._loaded_version:
            self.config = self.morphos.load(version) if version else self.base_config
            self._loaded_version = version

    @property
    def state(self):
        return self.store.read()

    @property
    def memx(self):
        return self.state["memx"]

    @property
    def memory(self):
        rows = [self.config.memory_schema(**{k: v for k, v in row.items() if k != "id"})
                for row in self.memx]
        return ListMemory(self.config.memory_schema, rows)

    @property
    def last_output(self):
        return self.state["last_output"]

    @property
    def sessions(self):
        """Bounded run summaries. Detailed transcripts are optional archive material."""
        return {job["id"]: {"flow": job["flow"], "status": job["status"], "tokens": job["tokens"]}
                for job in self.state["jobs"]}

    def transcript(self, job_id):
        path = safe_child(self.corpora.root / "archive", f"{self.agid}/runs/{job_id}.json")
        return json.loads(path.read_bytes())["logs"] if path.exists() else []

    def check(self, job_id):
        """Raise a concise error if a requested job has not completed successfully."""
        job = next((j for j in self.state["jobs"] if j["id"] == job_id), None)
        if job is None:
            raise KeyError("Job summary is no longer in the active window")
        if job["status"] != "done":
            raise RuntimeError(f"{job['status']}: {job.get('error', job['flow'])}")

    def result(self, job_id):
        self.check(job_id)
        for message in self.state["chat"]:
            if message.get("job") == job_id:
                return message["content"]
        path = safe_child(self.corpora.root / "archive", f"{self.agid}/runs/{job_id}.json")
        if not path.exists():
            raise FileNotFoundError("This result has left the active window and its archive was removed")
        return json.loads(path.read_bytes())["output"]

    @property
    def manifests(self):
        directory = self.root / "manifests"
        return {p.stem: p.read_text() for p in sorted(directory.glob("*.md"))}

    def status(self):
        state = self.state
        return {"agid": self.agid, "memory": len(state["memx"]),
                "queued": sum(j["status"] == "queued" for j in state["jobs"]),
                "running": sum(j["status"] == "running" for j in state["jobs"]),
                "needs_attention": sum(j["status"] in {"failed", "conflict", "interrupted", "budget_blocked"}
                                       for j in state["jobs"])}

    def events(self, after=0):
        return [event for event in self.state["events"] if event["sequence"] > after]

    def set_manifest(self, name, text):
        from .storage import atomic_bytes
        if not name or "/" in name or "\\" in name:
            raise ValueError("Use a simple manifest name")
        atomic_bytes(safe_child(self.root / "manifests", f"{name}.md"), text.encode())

    def _event(self, state, kind, **details):
        state["event_sequence"] += 1
        state["events"].append(dict(sequence=state["event_sequence"], time=utcnow().isoformat(),
                                    kind=kind, **details))

    def _trim(self, state):
        # Closed sprint ledgers are archival, provided no job still owns a reservation.
        ledgers = sorted(state["budgets"])
        for sprint in ledgers[:-2]:
            if state["budgets"][sprint]["reserved"] == 0:
                self.corpora.archive(self.agid, f"budgets/{sprint}", state["budgets"].pop(sprint))
        for field in ("chat", "notes", "events"):
            removed = state[field][:-self.limits.max_records]
            if removed:
                self.corpora.archive(self.agid, f"{field}/{uuid4().hex}", removed)
                state[field] = state[field][-self.limits.max_records:]
        terminal = [j for j in state["jobs"] if j["status"] in {"done", "cancelled"}]
        removed = terminal[:-self.limits.max_records]
        if removed:
            self.corpora.archive(self.agid, f"jobs/{uuid4().hex}", removed)
            ids = {j["id"] for j in removed}
            state["jobs"] = [j for j in state["jobs"] if j["id"] not in ids]

    def _enqueue(self, state, flow, task, key=None):
        if flow not in self.config.flows:
            raise ValueError(f"Unknown flow: {flow}")
        if key is not None:
            previous = next((j for j in state["jobs"] if j.get("key") == key), None)
            if previous:
                return previous["id"]
        if sum(j["status"] not in {"done", "cancelled"} for j in state["jobs"]) >= self.limits.max_records:
            raise ValueError("Job limit reached; finish or cancel existing work")
        job = dict(id=uuid4().hex, flow=flow, task=task, key=key, status="queued",
                   created=utcnow().isoformat(), tokens=0)
        state["jobs"].append(job)
        self._event(state, "queued", job=job["id"], flow=flow)
        return job["id"]

    def submit(self, flow, task="", *, key=None):
        with self.store.transaction() as state:
            job_id = self._enqueue(state, flow, task, key)
            self._trim(state)
        return job_id

    def tell(self, text):
        """Persist a user message and queue a conversation; call await agent.run()."""
        with self.store.transaction() as state:
            state["chat_revision"] += 1
            state["chat"].append(dict(role="user", content=text, time=utcnow().isoformat()))
            job_id = self._enqueue(state, "chat", text)
            self._trim(state)
        return job_id

    def consolidate(self):
        return self.submit("learning")

    def send(self, recipient, text, *, reply_to=None):
        return self.corpora.send(self.agid, recipient, text, reply_to=reply_to)

    def add_task(self, title, *, due=None, flow="reason", project=None):
        if due:
            self._time(due)
        if flow not in self.config.flows:
            raise ValueError("Unknown task flow")
        task = dict(id=uuid4().hex, title=title, due=due, flow=flow, project=project, status="open")
        with self.store.transaction() as state:
            if project and not any(p["id"] == project for p in state["projects"]):
                raise ValueError("Unknown project")
            state["tasks"].append(task)
        return task["id"]

    def finish_task(self, task_id):
        with self.store.transaction() as state:
            task = next(t for t in state["tasks"] if t["id"] == task_id)
            task["status"] = "done"
            self.corpora.archive(self.agid, f"tasks/{task_id}", task)
            state["tasks"].remove(task)

    def add_project(self, title, *, starts, ends, goals, metrics=None):
        if date.fromisoformat(ends) < date.fromisoformat(starts):
            raise ValueError("Project end precedes start")
        project = dict(id=uuid4().hex, title=title, starts=starts, ends=ends,
                       goals=goals, metrics=metrics or {})
        with self.store.transaction() as state:
            state["projects"].append(project)
        return project["id"]

    def measure(self, project_id, name, value):
        with self.store.transaction() as state:
            project = next(p for p in state["projects"] if p["id"] == project_id)
            project["metrics"][name] = value

    @staticmethod
    def _time(value):
        result = datetime.fromisoformat(value)
        if result.tzinfo is None:
            raise ValueError("Use a timezone-aware ISO datetime")
        return result

    def _sprint(self, now):
        schedule = self.budget_calendar
        day = now.astimezone(ZoneInfo(schedule.timezone)).date()
        anchor = date.fromisoformat(schedule.sprint_anchor)
        start = anchor + timedelta(days=((day - anchor).days // schedule.sprint_days) * schedule.sprint_days)
        return start.isoformat()

    def awake(self, *, now=None, force=False):
        """Cheap scheduling only. Incoming mail is persisted before acknowledgment."""
        now = now or utcnow()
        if now.tzinfo is None:
            raise ValueError("awake requires a timezone-aware datetime")
        schedule = getattr(self.config, "schedule", Schedule())
        acknowledged = []
        with self.store.transaction() as state:
            for message in self.corpora.pending(self.agid):
                if not self.corpora.received(self.agid, message["id"]):
                    if message["reply_to"]:
                        if not any(n.get("message") == message["id"] for n in state["notes"]):
                            state["notes"].append(dict(flow="mail", message=message["id"],
                                                       sender=message["sender"], reply_to=message["reply_to"],
                                                       content=message["text"]))
                            state["chat_revision"] += 1
                            self._event(state, "message_received", sender=message["sender"],
                                        reply_to=message["reply_to"])
                    else:
                        job_id = self._enqueue(state, "chat", json.dumps(message), key=f"mail:{message['id']}")
                        job = next(j for j in state["jobs"] if j["id"] == job_id)
                        job["reply_to"] = dict(sender=message["sender"], message=message["id"])
                acknowledged.append(message["id"])
            due = force or not state["next_awake"] or now >= self._time(state["next_awake"])
            if due:
                circa = not state["last_circa"] or now >= self._time(state["last_circa"]) + timedelta(hours=schedule.circa_hours)
                wake = Wake(now=now.isoformat(), changed=state["chat_revision"] > state["learned_revision"],
                            circa_due=circa, due_tasks=tuple(deepcopy(t) for t in state["tasks"]
                            if t["status"] == "open" and not t.get("job") and t["due"] and now >= self._time(t["due"])))
                for request in self.config.awake(wake):
                    job_id = self._enqueue(state, request.flow, request.task, request.key)
                    for task in state["tasks"]:
                        if task["id"] == request.key:
                            task["job"] = job_id
                state["next_awake"] = (now + timedelta(minutes=schedule.awake_minutes)).isoformat()
                if circa:
                    state["last_circa"] = now.isoformat()
            self._trim(state)
        for message_id in acknowledged:
            self.corpora.acknowledge(self.agid, message_id)
        self._flush_outbox()

    def _flush_outbox(self):
        for message in self.state.get("outbox", []):
            self.corpora.send(self.agid, message["recipient"], message["text"],
                              reply_to=message["reply_to"], message_id=message["id"])
            with self.store.transaction() as state:
                state["outbox"] = [m for m in state.get("outbox", []) if m["id"] != message["id"]]

    def _recover(self, state):
        # The runner lock proves no other runtime owns these jobs. Never replay
        # an interrupted external action automatically: its effect may have happened.
        for job in state["jobs"]:
            if job["status"] == "running":
                self._settle(state, job, job["reserved"])
                job["status"] = "interrupted"
                job["error"] = "Runner stopped before committing; inspect effects before retrying"
                self._event(state, "interrupted", job=job["id"])

    def _reserve(self, state, job, loop_remaining, now):
        flow = self.config.flows[job["flow"]]
        reserved = sum(isinstance(s, str) for s in flow.steps) * self.limits.tokens_per_call
        sprint = self._sprint(now)
        ledger = state["budgets"].setdefault(sprint, {"spent": 0, "reserved": 0})
        if reserved > loop_remaining or ledger["spent"] + ledger["reserved"] + reserved > self.limits.tokens_per_sprint:
            job["status"] = "budget_blocked"
            self._event(state, "budget_blocked", job=job["id"])
            return None
        job.update(status="running", reserved=reserved, sprint=sprint,
                   mem_revision=state["mem_revision"], chat_revision=state["chat_revision"],
                   morphos_version=state["morphos_version"])
        ledger["reserved"] += reserved
        self._event(state, "started", job=job["id"], flow=job["flow"])
        return reserved

    @staticmethod
    def _settle(state, job, tokens):
        ledger = state["budgets"][job["sprint"]]
        ledger["reserved"] -= job["reserved"]
        ledger["spent"] += tokens
        job["tokens"] = tokens

    def _context(self, snapshot, task):
        blocks = dict(manifests=snapshot["inputs"]["manifests"], memory=snapshot["memx"], chat=snapshot["chat"],
                      goals=snapshot["projects"], tasks=snapshot["tasks"], notes=snapshot["notes"])
        return {**{k: json.dumps(v, ensure_ascii=False) for k, v in blocks.items()},
                "context": json.dumps(blocks, ensure_ascii=False), "task": task,
                "last": "", "proposal": "", "critique": "",
                "body": json.dumps(snapshot["inputs"]["body"], ensure_ascii=False),
                "corpora": str(self.corpora.root),
                "directory": json.dumps(snapshot["inputs"]["directory"], ensure_ascii=False)}

    def _work(self, job, snapshot, config):
        result = Outcome()
        try:
            context = self._context(snapshot, job["task"])
            llm_index = 0
            for step in config.flows[job["flow"]].steps:
                if isinstance(step, Python):
                    context[step.output] = step.function(deepcopy(context))
                    continue
                role = config.roles[step]
                prompt = role.prompt.format_map(context).strip()
                if len(prompt) > self.limits.context_chars:
                    raise ValueError("Prompt exceeds context limit; reduce inputs or consolidate")
                if result.tokens + self.limits.tokens_per_call > job["reserved"]:
                    raise ValueError("Flow token allowance exhausted")
                llm = self.factory.spawn(LLMSpec(role=step, model=role.model))
                log = dict(role=step, prompt=prompt, session=llm.id)
                result.logs.append(log)
                try:
                    answer = llm.complete(prompt)
                    log["answer"] = answer
                finally:
                    usage = getattr(llm, "usage", None)
                    charged = (usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
                               if usage is not None else self.limits.tokens_per_call)
                    result.tokens += charged
                    log.update(session=llm.id, usage=usage, charged=charged)
                if not isinstance(answer, str):
                    raise ValueError("LLM output must be text")
                context["last"] = answer
                if llm_index == 0:
                    context["proposal"] = answer
                elif llm_index == 1:
                    context["critique"] = answer
                llm_index += 1
            result.output = context["last"]
        except Exception as error:
            result.error = f"{type(error).__name__}: {error}"
        return result

    def _memory_patch(self, state, output):
        patch = json.loads(output)
        if not isinstance(patch, dict) or set(patch) != {"upsert", "forget"}:
            raise ValueError("Memory output requires upsert and forget")
        if not isinstance(patch["upsert"], list) or not isinstance(patch["forget"], list):
            raise ValueError("Memory upsert and forget must be lists")
        existing = {row["id"]: row for row in state["memx"]}
        for key in patch["forget"]:
            if not isinstance(key, str) or key not in existing:
                raise ValueError("Cannot forget an unknown memory ID")
        # Parse all rows before mutating. Custom schema validation belongs to Config.
        updates = []
        for row in patch["upsert"]:
            if not isinstance(row, dict):
                raise ValueError("Memory rows must be objects")
            content = dict(row)
            key = content.pop("id", None)
            if key is not None and (not isinstance(key, str) or key not in existing):
                raise ValueError("Updates must reference an existing memory ID")
            parsed = self.config.parse_memory(json.dumps([content]))[0]
            payload = asdict(parsed)
            semantic = {k: v for k, v in payload.items() if k != "updated_at"}
            duplicate = next((r["id"] for r in existing.values()
                              if {k: v for k, v in r.items() if k not in {"id", "updated_at"}} == semantic), None)
            updates.append(dict(id=key or duplicate or uuid4().hex, **payload))
        for key in patch["forget"]:
            del existing[key]
        existing.update({row["id"]: row for row in updates})
        if len(existing) > self.limits.max_records:
            raise ValueError("Memory record limit exceeded; consolidate more aggressively")
        self.corpora.archive(self.agid, f"memory/{state['mem_revision']}", state["memx"])
        state["memx"] = list(existing.values())
        state["mem_revision"] += 1

    def _finish(self, job_id, outcome, config, candidate=None):
        self.corpora.archive(self.agid, f"runs/{job_id}", asdict(outcome))
        try:
            with self.store.transaction() as state:
                job = next(j for j in state["jobs"] if j["id"] == job_id)
                self._settle(state, job, outcome.tokens)
                flow = config.flows[job["flow"]]
                if outcome.error:
                    job.update(status="failed", error=outcome.error)
                elif flow.commit in {"memory", "morphos"} and (
                    state["mem_revision"] != job["mem_revision"] or
                    state["morphos_version"] != job["morphos_version"] or
                    hashlib.sha256(encode(self.manifests)).hexdigest() != job["manifest_digest"] or
                    (flow.commit == "morphos" and hashlib.sha256(
                        encode(self.morphos.files(job["morphos_version"]))).hexdigest() != job["body_digest"])
                ):
                    job.update(status="conflict", error="State changed while reasoning; rerun on fresh state")
                else:
                    if flow.commit == "memory":
                        self._memory_patch(state, outcome.output)
                        state["learned_revision"] = max(state["learned_revision"], job["chat_revision"])
                    elif flow.commit == "morphos":
                        if candidate:
                            state["previous_morphos"] = state["morphos_version"]
                            state["morphos_version"] = candidate
                    elif flow.commit == "reply":
                        state["chat"].append(dict(role="agent", content=outcome.output, job=job_id,
                                                  time=utcnow().isoformat()))
                        state["chat_revision"] += 1
                        state["last_output"] = outcome.output
                        if job.get("reply_to"):
                            state.setdefault("outbox", []).append(dict(
                                id=f"reply_{job_id}", recipient=job["reply_to"]["sender"],
                                reply_to=job["reply_to"]["message"], text=outcome.output))
                    elif flow.commit == "note":
                        state["notes"].append(dict(flow=job["flow"], content=outcome.output))
                        state["chat_revision"] += 1
                    else:
                        raise ValueError(f"Unknown commit type: {flow.commit}")
                    job["status"] = "done"
                self._event(state, job["status"], job=job_id)
                self._trim(state)
        except Exception as error:
            # An invalid/oversized result must not lose usage accounting or poison state.
            with self.store.transaction() as state:
                job = next(j for j in state["jobs"] if j["id"] == job_id)
                self._settle(state, job, outcome.tokens)
                job.update(status="failed", error=str(error)[:500])
                self._event(state, "failed", job=job_id)
                self._trim(state)

    async def run(self):
        """Drain work, admitting new messages while background jobs are running."""
        try:
            lock = file_lock(self.root / ".runner.lock", blocking=False)
            lock.__enter__()
        except BlockingIOError:
            return  # Another runner already owns this agent.
        try:
            self._load_body(self.state)
            config = self.config
            loop_remaining = self.limits.tokens_per_loop
            active_version = self.state["morphos_version"]
            attempted = set()
            with self.store.transaction() as state:
                self._recover(state)

            def admit():
                nonlocal loop_remaining
                current = self.state
                if current["morphos_version"] != active_version or not any(
                    j["status"] in {"queued", "budget_blocked"} and j["id"] not in attempted
                    for j in current["jobs"]
                ):
                    return []
                selected = []
                inputs = dict(manifests=self.manifests, body=self.morphos.files(active_version),
                              directory=self.corpora.directory())
                with self.store.transaction() as state:
                    for job in state["jobs"]:
                        if job["status"] not in {"queued", "budget_blocked"} or job["id"] in attempted:
                            continue
                        attempted.add(job["id"])
                        amount = self._reserve(state, job, loop_remaining, utcnow())
                        if amount is not None:
                            loop_remaining -= amount
                            job["manifest_digest"] = hashlib.sha256(encode(inputs["manifests"])).hexdigest()
                            job["body_digest"] = hashlib.sha256(encode(inputs["body"])).hexdigest()
                            snapshot = deepcopy(state)
                            snapshot["inputs"] = deepcopy(inputs)
                            selected.append((deepcopy(job), snapshot))
                    self._trim(state)
                return selected
            semaphore = asyncio.Semaphore(self.limits.parallel_jobs)

            async def execute(job, snapshot):
                async with semaphore:
                    outcome = await asyncio.to_thread(self._work, job, snapshot, config)
                    candidate = None
                    if not outcome.error and config.flows[job["flow"]].commit == "morphos":
                        try:
                            proposal = json.loads(outcome.output)
                            if set(proposal) != {"files"} or not isinstance(proposal["files"], dict):
                                raise ValueError("Morphosis output requires a files object")
                            if proposal["files"]:
                                candidate = await asyncio.to_thread(self.morphos.stage, proposal["files"],
                                                                    base=job["morphos_version"])
                        except Exception as error:
                            outcome.error = str(error)
                    self._finish(job["id"], outcome, config, candidate)

            pending = {asyncio.create_task(execute(job, snapshot)) for job, snapshot in admit()}
            errors = []
            try:
                while pending:
                    done, pending = await asyncio.wait(pending, timeout=0.1,
                                                       return_when=asyncio.FIRST_COMPLETED)
                    errors.extend(task.exception() for task in done if task.exception() is not None)
                    if not errors:
                        pending.update(asyncio.create_task(execute(job, snapshot)) for job, snapshot in admit())
            finally:
                # Retain ownership through cancellation or storage failure until all
                # bounded worker calls finish; threads cannot be safely cancelled.
                if pending:
                    await asyncio.gather(*pending, return_exceptions=True)
            if errors:
                raise errors[0]
            self._flush_outbox()
        finally:
            lock.__exit__(None, None, None)

    async def tick(self, *, now=None, force=False):
        # Activate newly committed behavior only between runner invocations.
        try:
            with file_lock(self.root / ".runner.lock", blocking=False):
                self._load_body(self.state)
        except BlockingIOError:
            return
        self.awake(now=now, force=force)
        await self.run()

    def retry(self, job_id):
        with self.store.transaction() as state:
            job = next(j for j in state["jobs"] if j["id"] == job_id)
            if job["status"] not in {"failed", "conflict", "interrupted", "budget_blocked"}:
                raise ValueError("Only stopped jobs can be retried")
            job["status"] = "queued"
            job.pop("error", None)

    def cancel(self, job_id):
        with self.store.transaction() as state:
            job = next(j for j in state["jobs"] if j["id"] == job_id)
            if job["status"] == "running":
                raise ValueError("Wait for running work to finish before cancelling")
            job["status"] = "cancelled"
            self._trim(state)

    def rollback(self):
        with file_lock(self.root / ".runner.lock", blocking=False):
            with self.store.transaction() as state:
                state["morphos_version"], state["previous_morphos"] = (
                    state["previous_morphos"], state["morphos_version"])
                self._event(state, "morphos_rollback")
            self._load_body(self.state)

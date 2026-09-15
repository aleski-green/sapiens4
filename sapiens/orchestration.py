"""Host scheduling and validated operations; runtime data stays with AgentPy."""
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import json
import shlex
import sys

from .runtime import ROOT
from agentpy.storage import atomic_bytes


def utcnow():
    return datetime.now(timezone.utc)


class Orchestration:
    def __init__(self, service):
        self.service = service
        self.url = None

    def settings(self, agent):
        path = agent.root / "host.json"
        if not path.exists():
            self.save(agent, dict(enabled=True, minutes=10, monitor_team=False,
                                  next_check=(utcnow() + timedelta(minutes=10)).isoformat(),
                                  last_check=None, consolidate_requested=False))
        return json.loads(path.read_text())

    @staticmethod
    def save(agent, settings):
        atomic_bytes(agent.root / "host.json", json.dumps(settings).encode())

    def attach(self, url):
        self.url = url
        for agent in self.service._agents.values():
            self.prepare(agent)

    def prepare(self, agent):
        settings = self.settings(agent)
        agent.config.schedule = replace(agent.config.schedule, awake_minutes=settings["minutes"])
        if self.url:
            path = self.service.root / "workspaces" / agent.agid / "host-control.json"
            atomic_bytes(path, json.dumps({"url": f"{self.url}/api/agents/{agent.agid}/control"}).encode())
            command = " ".join(shlex.quote(str(p)) for p in (sys.executable, ROOT / "sapiens/control.py", path))
            agent.set_manifest("host-control", f"""Internal Sapiens4 operations: run {command} '<JSON object>'.
Pass a JSON object with op and the fields below. Quote JSON safely for the shell.
- status: current self facts and team job/task progress; no other fields needed.
- schedule: optional minutes (integer 1–1440), enabled (boolean), monitor_team
  (boolean). Applies to you. A five-minute team check uses minutes=5,
  enabled=true, monitor_team=true. Checks run while this host is running;
  busy work can delay them. Unchanged checks do not start model calls.
- manager: manager (unique name or ID, or null to clear); optional target
  (unique name or ID, defaults to you). Persists the reporting relationship.
- task: title (text), due (ISO datetime with timezone, or null for unscheduled).
  Saves your task; due tasks run the SDK reasoning flow. This does not authorize
  computer actions. status returns task IDs and their associated job results.
- finish_task: id (existing task ID). Only mark done when its result is verified.
- consolidate: queues memory learning after the current conversation completes.
Never edit host-control.json or runtime files. Report errors from the command.
The returned saved facts are authoritative. Do not replay old chat requests.
""")
        facts = self.status(agent)
        # Full job transcripts and task lists are fetched on demand, rather than
        # duplicating them into every chat and memory prompt.
        facts["team"] = [{k: v for k, v in member.items() if k not in {"recent_jobs", "tasks"}}
                         for member in facts["team"]]
        agent.set_manifest("host-facts", json.dumps(facts, ensure_ascii=False))

    def team(self):
        rows = self.service.store.agents()
        directory = next(iter(self.service._agents.values())).corpora.directory()
        result = []
        for row in rows:
            agent = self.service._agent(row["id"])
            state = agent.state
            jobs = state["jobs"]
            outputs = {m.get("job"): m["content"] for m in state["chat"]}
            for job in jobs[-5:]:
                if job["status"] == "done" and job["id"] not in outputs:
                    try:
                        outputs[job["id"]] = agent.result(job["id"])
                    except FileNotFoundError:
                        pass
            result.append(dict(id=row["id"], name=row["name"], role=row["role"],
                manager=directory.get(row["id"], {}).get("parent"),
                tasks=state["tasks"], memory_entries=len(state["memx"]),
                needs_attention=sum(j["status"] in {"failed", "interrupted", "conflict", "budget_blocked"} for j in jobs),
                recent_jobs=[dict(id=j["id"], flow=j["flow"], status=j["status"],
                                 task=j["task"][:500], error=j.get("error"),
                                 result=outputs.get(j["id"], "")[:500]) for j in jobs[-5:]]))
        return result

    def status(self, agent):
        return dict(self_id=agent.agid, schedule=self.settings(agent), team=self.team())

    def resolve(self, value):
        from .service import APIError
        rows = self.service.store.agents()
        matches = [r for r in rows if r["id"] == value]
        if not matches and isinstance(value, str):
            matches = [r for r in rows if r["name"].casefold() == value.casefold()]
        if len(matches) != 1:
            raise APIError(400, "Sapi name must identify exactly one existing Sapi; use its ID")
        return self.service._agent(matches[0]["id"])

    def control(self, agid, data):
        from .service import APIError, text_field
        with self.service._lock:
            agent = self.service._agent(agid)
            op = data.get("op")
            fields = {"status": set(), "schedule": {"minutes", "enabled", "monitor_team"},
                      "manager": {"manager", "target"}, "task": {"title", "due"},
                      "finish_task": {"id"}, "consolidate": set()}
            if not isinstance(op, str) or op not in fields or set(data) - fields[op] - {"op"}:
                raise APIError(400, "Unknown operation or field")
            result = {}
            if op == "schedule":
                settings = self.settings(agent)
                minutes = data.get("minutes", settings["minutes"])
                if type(minutes) is not int or not 1 <= minutes <= 1440:
                    raise APIError(400, "minutes must be an integer from 1 to 1440")
                for key in ("enabled", "monitor_team"):
                    if key in data and type(data[key]) is not bool:
                        raise APIError(400, f"{key} must be boolean")
                settings.update({k: v for k, v in data.items() if k != "op"})
                settings["next_check"] = ((utcnow() + timedelta(minutes=minutes)).isoformat()
                                          if settings["enabled"] else None)
                self.save(agent, settings)
                agent.config.schedule = replace(agent.config.schedule, awake_minutes=minutes)
            elif op == "manager":
                if "manager" not in data:
                    raise APIError(400, "manager is required; use null to clear it")
                target = self.resolve(data["target"]) if "target" in data else agent
                parent = self.resolve(data["manager"]) if data["manager"] is not None else None
                entry = target.corpora.directory()[target.agid]
                target.corpora.register(target.agid, parent=parent.agid if parent else None, scope=entry["scope"])
                result = {"target": target.agid, "manager": parent.agid if parent else None}
            elif op == "task":
                title = text_field(data, "title", 2000)
                due = data.get("due")
                if due is not None:
                    if not isinstance(due, str) or not due:
                        raise APIError(400, "due must be a timezone-aware ISO datetime or null")
                    agent._time(due)
                result["task_id"] = agent.add_task(title, due=due, flow="reason")
            elif op == "finish_task":
                task_id = text_field(data, "id", 64)
                if not any(t["id"] == task_id for t in agent.state["tasks"]):
                    raise APIError(404, "Unknown open task")
                agent.finish_task(task_id)
                result["completed_task_id"] = task_id
            elif op == "consolidate":
                settings = self.settings(agent)
                settings["consolidate_requested"] = True
                self.save(agent, settings)
                result["status"] = "queued"
            if op != "status":
                self.service.store.event(agid, "control", json.dumps(data), job=self.service._active_job(agid))
            return {**self.status(agent), **result}

    def due(self, agent, instant):
        settings = self.settings(agent)
        return settings["enabled"] and (not settings["next_check"] or
                    instant >= datetime.fromisoformat(settings["next_check"]))

    def checked(self, agent, instant):
        settings = self.settings(agent)
        settings["last_check"] = instant.isoformat()
        settings["next_check"] = (instant + timedelta(minutes=settings["minutes"])).isoformat()
        if settings["monitor_team"]:
            team = self.team()
            digest = hashlib.sha256(json.dumps(team, sort_keys=True).encode()).hexdigest()
            if settings.get("team_digest") != digest:
                self.service.store.event(agent.agid, "team_check", json.dumps(team, ensure_ascii=False))
            settings["team_digest"] = digest
            settings["team_checked_at"] = instant.isoformat()
        self.save(agent, settings)
        self.service.store.event(agent.agid, "heartbeat", "Checked due tasks and " +
                                 ("team progress" if settings["monitor_team"] else "memory schedule"))

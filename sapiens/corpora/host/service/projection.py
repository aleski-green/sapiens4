from __future__ import annotations

import os
import sys
from sapiens.corpora.sapis.attachments import resolve_attachments
from sapiens.prompts import prompt
from sapiens.corpora.sapis.notes import Notes
from sapiens.runtime.settings import execution_settings
from sapiens.validation import APIError


class Projection:
    def __init__(self, host):
        self.host = host
        self.revisions: dict[str, int] = {}

    def sync(self, agent):
        snapshot = agent.state
        if self.revisions.get(agent.agid) == snapshot["revision"]:
            return
        outputs = {m["turn"]: m["content"] for m in snapshot["chat"] if m.get("turn") and m["role"] == "agent"}
        for turn in snapshot["turns"]:
            if turn["status"] == "done" and turn["id"] not in outputs and turn.get("batch_id", turn["id"]) == turn["id"]:
                try:
                    outputs[turn["id"]] = agent.result(turn["id"])
                except FileNotFoundError:
                    pass  # An explicitly pruned archive need not block projection.
        self.host.store.project(agent.agid, snapshot, outputs)
        self.revisions[agent.agid] = snapshot["revision"]

    def corpora_identity(self):
        return self.host.corpora_settings.identity()

    def snapshot(self, agid=None):
        host = self.host
        with host._lock:
            if agid:
                host.population.agent(agid)
            for agent in host.population.agents.values():
                self.sync(agent)
            host.groups.chat.reconcile()
            snapshot = host.store.snapshot(agid)
            snapshot['corpora'] = self.corpora_identity()
            snapshot["groups"] = host.groups.snapshot()
            snapshot["routines"] = host.store.routines()
            snapshot["creation_template"] = prompt("creation-request").strip()
            group_turns = {r["id"]: g["id"] for g in snapshot["groups"] for r in g["requests"]}
            for turn in snapshot["turns"]:
                if turn["id"] in group_turns:
                    turn["group"] = group_turns[turn["id"]]
            for row in snapshot['agents']:
                row['retired'] = host.lifecycle.retired(host.population.agent(row['id']))
            snapshot["computer"] = {"owner": host.execution.owner,
                                    "built": os.access(host.binary, os.X_OK), "platform": sys.platform}
            snapshot['pulses'] = host.store.pulse_calls(agid)
            snapshot['events'] = host.store.events.snapshot(agid)
            snapshot['pulse'] = dict(id=host.pulse.identity, running=host.pulse.running, numbers=dict(host.pulse.numbers))
            snapshot["provider"] = "codex"
            snapshot['activity'] = {a.agid: {**getattr(a.runner.active_llm, 'activity', {}),
                'turn': host.execution.active_turn(a.agid), 'stopping': a.runner.cancel_event.is_set()}
                for a in host.population.agents.values() if host.execution.active_turn(a.agid)}
            snapshot['run_activity'] = {}
            for (owner, kind, slot), (runner, _, batch_id) in host.agencies.slots.items():
                activity = dict(getattr(runner.active_llm, 'activity', {}), turn=batch_id,
                                stopping=runner.cancel_event.is_set(), agencyKind=kind, slot=slot)
                snapshot['run_activity'][batch_id] = activity
                snapshot['activity'][owner] = activity
            snapshot["main_agent_id"] = host.registry.main
            workloads = host.store.workloads()
            snapshot["workloads"] = host.delegation.summaries(workloads)
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
                agid: [a for a in host.store.attachments(agid) if a["id"] in ids]
                for agid, ids in snapshot["preferences"].get("attachment_drafts", {}).items()}

            snapshot["orchestration"] = {
                a.agid: {"manager": host.registry.directory().get(a.agid, {}).get("parent"),
                         "execution": execution_settings(a.root),
                         "notes": Notes(host.workspace.root(a)).metadata()}
                for a in host.population.agents.values()}
            return snapshot

    def save_preferences(self, data):
        host = self.host
        # Browser state never gets authority over runtime turns, agents or computer ownership.
        if set(data) - {"selected", "panel", "scope", "groupView", "panes", "drafts", "attachment_drafts"}:
            raise APIError(400, "Unknown preference field")
        for field in ("panes", "drafts", "attachment_drafts"):
            if field in data and not isinstance(data[field], dict):
                raise APIError(400, f"{field} must be an object")
        if "selected" in data and data["selected"] not in {a["id"] for a in host.store.agents()} | {g["id"] for g in host.store.groups()}:
            raise APIError(400, "Unknown selected Sapi")
        if data.get("groupView") is not None and data["groupView"] not in {g["id"] for g in host.store.groups()}:
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
            resolve_attachments(host, agid, ids, check_files=False)
        with host._lock:
            current = host.store.read_preferences()
            current.update(data)
            host.store.preferences(current)
            return {"saved": True, "preferences": current}

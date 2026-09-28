"""Deterministic lifecycle tests; never invoke Codex or modify real agent state."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import shutil
import tempfile
import threading
import unittest

from agentpy import Flow, Limits, Python, Role
from agentpy.runtime import PersistentAgent
from agentpy.config import Config
from sapiens.paths import BEHAVIOR_SOURCE
from types import SimpleNamespace


ROW = dict(kind="preference", content="Keep replies concise", evidence="User asked",
           salience=1, tags=["style"])


class FakeFactory:
    def __init__(self, outputs=None, barrier=None):
        self.outputs = outputs or {}
        self.calls = []
        self.barrier = barrier

    def spawn(self, spec):
        llm = SimpleNamespace(spec=spec, id="test-session")
        def complete(prompt):
            self.calls.append((spec.role, prompt))
            if self.barrier and spec.role == "conversation":
                self.barrier.wait(timeout=3)
            value = self.outputs.get(spec.role, {
                "memory_arbiter": json.dumps(dict(upsert=[ROW], forget=[])),
                "morphos_arbiter": '{"files": {}}',
            }.get(spec.role, "A concise response"))
            if isinstance(value, Exception):
                raise value
            if callable(value):
                value = value(prompt)
            llm.usage = {"input_tokens": 10, "output_tokens": 5}
            return value
        llm.complete = complete
        return llm


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def agent(self, factory=None, config=None, agid="test", **options):
        return PersistentAgent(config=config or Config(), factory=factory or FakeFactory(),
                            agid=agid, root=self.root, **options)

    def test_restart_and_archive_independence(self):
        agent = self.agent()
        agent.tell("Remember my preference")
        asyncio.run(agent.run())
        agent.consolidate()
        asyncio.run(agent.run())
        self.assertEqual(agent.memx[0]["content"], ROW["content"])
        shutil.rmtree(agent.corpora.root / "archive")
        restored = self.agent()
        self.assertEqual(restored.memx, agent.memx)
        self.assertEqual(restored.last_output, "A concise response")
        restored.tell("Continue")
        asyncio.run(restored.run())
        self.assertEqual(restored.status()["needs_attention"], 0)

    def test_idle_wake_is_free_and_due_task_deduplicates(self):
        factory = FakeFactory()
        agent = self.agent(factory)
        now = datetime(2026, 9, 15, tzinfo=timezone.utc)
        asyncio.run(agent.tick(now=now))
        self.assertEqual(factory.calls, [])
        agent.add_task("Review", due=now.isoformat())
        agent.awake(now=now + timedelta(minutes=10))
        agent.awake(now=now + timedelta(minutes=20))
        self.assertEqual(len(agent.state["jobs"]), 1)

    def test_jobs_actually_run_in_parallel_and_writes_are_not_lost(self):
        agent = self.agent(FakeFactory(barrier=threading.Barrier(2)))
        agent.tell("First")
        agent.tell("Second")
        asyncio.run(agent.run())
        self.assertEqual([j["status"] for j in agent.state["jobs"]], ["done", "done"])
        self.assertEqual(len(agent.state["chat"]), 4)
        self.assertEqual(sum(b["spent"] for b in agent.state["budgets"].values()), 30)

    def test_chat_arriving_during_background_work_is_admitted(self):
        started, release = threading.Event(), threading.Event()
        def slow_reasoning(prompt):
            started.set()
            if not release.wait(timeout=5):
                raise TimeoutError("Background test was not released")
            return "A proposal"
        agent = self.agent(FakeFactory({"reasoner": slow_reasoning}))
        agent.submit("reason", "Background review")
        async def exercise():
            running = asyncio.create_task(agent.run())
            await asyncio.to_thread(started.wait, 3)
            job = self.agent().tell("While you are working...")
            try:
                for _ in range(100):
                    current = next(j for j in agent.state["jobs"] if j["id"] == job)
                    if current["status"] == "done":
                        break
                    await asyncio.sleep(0.02)
                self.assertEqual(current["status"], "done")
                self.assertFalse(running.done())
                self.assertEqual(agent.result(job), "A concise response")
            finally:
                release.set()
                await running
        asyncio.run(exercise())

    def test_changed_manifest_rejects_old_memory_proposal(self):
        factory = FakeFactory()
        agent = self.agent(factory)
        def change_manifest(prompt):
            agent.set_manifest("rules", "New human instructions")
            return json.dumps(dict(upsert=[ROW], forget=[]))
        factory.outputs["memory_arbiter"] = change_manifest
        agent.consolidate()
        asyncio.run(agent.run())
        self.assertEqual(agent.memx, [])
        self.assertEqual(agent.state["jobs"][0]["status"], "conflict")

    def test_memory_correction_and_removal(self):
        factory = FakeFactory()
        agent = self.agent(factory)
        agent.consolidate()
        asyncio.run(agent.run())
        key = agent.memx[0]["id"]
        factory.outputs["memory_arbiter"] = json.dumps(dict(upsert=[dict(ROW, id=key, content="Use examples")], forget=[]))
        agent.consolidate()
        asyncio.run(agent.run())
        self.assertEqual(agent.memx[0]["id"], key)
        self.assertEqual(agent.memx[0]["content"], "Use examples")
        factory.outputs["memory_arbiter"] = json.dumps(dict(upsert=[], forget=[key]))
        agent.consolidate()
        asyncio.run(agent.run())
        self.assertEqual(agent.memx, [])

    def test_concurrent_submitters(self):
        agents = [self.agent(), self.agent()]
        with ThreadPoolExecutor(2) as pool:
            list(pool.map(lambda i: agents[i % 2].tell(str(i)), range(20)))
        self.assertEqual(len(agents[0].state["jobs"]), 20)
        self.assertEqual(len(agents[0].state["chat"]), 20)

    def test_stale_memory_result_is_not_committed(self):
        agent = self.agent()
        agent.consolidate()
        agent.consolidate()
        asyncio.run(agent.run())
        self.assertEqual(sorted(j["status"] for j in agent.state["jobs"]), ["conflict", "done"])
        self.assertEqual(len(agent.memx), 1)

    def test_invalid_patch_preserves_memory_and_accounts_usage(self):
        agent = self.agent(FakeFactory({"memory_arbiter": "invalid"}))
        agent.consolidate()
        asyncio.run(agent.run())
        self.assertEqual(agent.memx, [])
        self.assertEqual(agent.state["jobs"][0]["status"], "failed")
        self.assertEqual(agent.state["jobs"][0]["tokens"], 45)

    def test_budget_admission_and_calendar_persist(self):
        limits = replace(Limits(), tokens_per_sprint=16_000)
        agent = self.agent(limits=limits)
        agent.tell("One")
        agent.tell("Two")
        asyncio.run(agent.run())
        self.assertEqual([j["status"] for j in agent.state["jobs"]], ["done", "budget_blocked"])
        reopened = self.agent()
        self.assertEqual(reopened.limits.tokens_per_sprint, 16_000)
        self.assertEqual(reopened.budget_calendar, agent.budget_calendar)

    def test_interrupted_job_is_not_replayed(self):
        factory = FakeFactory()
        agent = self.agent(factory)
        job_id = agent.tell("External action")
        with agent.store.transaction() as state:
            agent._reserve(state, state["jobs"][0], 100_000, datetime.now(timezone.utc))
        asyncio.run(self.agent(factory).run())
        self.assertEqual(factory.calls, [])
        self.assertEqual(agent.state["jobs"][0]["status"], "interrupted")
        self.assertEqual(agent.state["jobs"][0]["tokens"], 16_000)
        agent.retry(job_id)
        asyncio.run(agent.run())
        self.assertEqual(agent.state["jobs"][0]["status"], "done")

    def test_python_pipes_and_exact_prompts(self):
        config = Config()
        config.roles = {"a": Role("exact: {task}"), "b": Role("{last}")}
        config.flows = {"pipe": Flow(("a", Python(lambda ctx: ctx["last"].upper()), "b"))}
        factory = FakeFactory({"a": "small", "b": "done"})
        agent = self.agent(factory, config)
        agent.submit("pipe", "hello")
        asyncio.run(agent.run())
        self.assertEqual(factory.calls, [("a", "exact: hello"), ("b", "SMALL")])

    def test_archive_window_and_state_size(self):
        agent = self.agent(limits=replace(Limits(), max_records=2))
        for _ in range(3):
            agent.tell("Hello")
            asyncio.run(agent.run())
        self.assertEqual(len(agent.state["chat"]), 2)
        self.assertEqual(len(agent.state["jobs"]), 2)
        self.assertTrue(list((agent.corpora.root / "archive" / agent.agid / "chat").glob("*.json")))
        before = agent.state
        with self.assertRaises(ValueError):
            agent.tell("x" * 1_000_001)
        self.assertEqual(agent.state, before)

    def test_hierarchy_mailbox_and_artifacts(self):
        director = self.agent(agid="director")
        worker = self.agent(agid="worker")
        director.corpora.register("worker", parent="director", scope="Research")
        with self.assertRaises(ValueError):
            director.corpora.register("director", parent="worker")
        message_id = director.send("worker", "Please review")
        worker.awake()
        worker.awake()
        self.assertEqual(len(worker.state["jobs"]), 1)
        self.assertEqual(worker.state["jobs"][0]["key"], f"mail:{message_id}")
        self.assertEqual(worker.corpora.pending("worker"), [])
        director.corpora.put("research/result.txt", "Useful evidence")
        self.assertEqual(worker.corpora.read("research/result.txt"), b"Useful evidence")
        with self.assertRaises(ValueError):
            director.corpora.put("../../escape", "no")
        asyncio.run(worker.run())
        reply = director.corpora.pending("director")[0]
        self.assertEqual(reply["reply_to"], message_id)
        director.awake()
        self.assertEqual(director.state["notes"][0]["content"], "A concise response")
        self.assertFalse(any(j["flow"] == "chat" for j in director.state["jobs"]))
        # Replaying outbox delivery after a sender crash must not recreate consumed mail.
        worker.corpora.send("worker", "director", reply["text"], reply_to=message_id, message_id=reply["id"])
        self.assertEqual(director.corpora.pending("director"), [])

    def test_morphosis_validation_activation_and_rollback(self):
        source = BEHAVIOR_SOURCE
        files = {"prompts/conversation.md": "New behavior: {task}"}
        factory = FakeFactory({"morphos_arbiter": json.dumps({"files": files})})
        agent = self.agent(factory, source=source)
        agent.submit("morphosis")
        asyncio.run(agent.run())
        version = agent.state["morphos_version"]
        self.assertIsNotNone(version)
        reopened = self.agent(factory, source=source)
        reopened.tell("Hello")
        asyncio.run(reopened.run())
        self.assertEqual(factory.calls[-1], ("conversation", "New behavior: Hello"))
        reopened.rollback()
        self.assertIsNone(reopened.state["morphos_version"])
        with self.assertRaises(ValueError):
            agent.morphos.stage({"agentpy/runtime.py": "bad"})
        with self.assertRaises(SyntaxError):
            agent.morphos.stage({"config.py": "bad syntax !"})
        with self.assertRaises(ValueError):
            agent.morphos.stage({"prompts/conversation.md": "Unknown {placeholder}"})



if __name__ == "__main__":
    unittest.main()

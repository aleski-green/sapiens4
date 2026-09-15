from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

from sapiens.assets import javascript
from sapiens.runtime import LocalFactory
from sapiens.server import Server
from sapiens.service import APIError, Service


class ScriptedLLM:
    id = "test-session"
    usage = {"input_tokens": 4, "output_tokens": 3}

    def __init__(self, factory):
        self.factory = factory

    def complete(self, prompt):
        self.factory.prompts.append(prompt)
        self.factory.started.set()
        self.factory.sink("Test worker started")
        if self.factory.gate:
            if not self.factory.gate.wait(5):
                raise TimeoutError("Test gate timed out")
        if self.factory.fail:
            raise RuntimeError("Scripted provider failure")
        return "Connected through AgentPy."


class ScriptedFactory:
    def __init__(self, gate=None, fail=False):
        self.gate, self.fail = gate, fail
        self.started = threading.Event()
        self.prompts = []
        self.sink = lambda text: None

    def builder(self, agid, sink):
        self.sink = sink
        return self

    def spawn(self, spec):
        return ScriptedLLM(self)


class IntegrationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.factory = ScriptedFactory()
        self.services = []
        self.addCleanup(self.close_services)

    def close_services(self):
        for service in self.services:
            service.close()

    def service(self, **kwargs):
        service = Service(self.directory.name, factory_builder=self.factory.builder, **kwargs)
        self.services.append(service)
        return service

    def restart(self, service, **kwargs):
        service.close()
        self.services.remove(service)
        return self.service(**kwargs)

    def wait_job(self, service, job_id, status="done"):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            job = next(j for j in service.snapshot()["jobs"] if j["id"] == job_id)
            if job["status"] == status:
                return job
            time.sleep(0.01)
        self.fail(f"Job did not reach {status}: {job}")

    def test_chat_projects_reply_and_survives_restart(self):
        service = self.service()
        agid = service.store.agents()[0]["id"]
        job = service.submit(agid, {"text": "Hello"})
        done = self.wait_job(service, job["id"])
        self.assertEqual(done["output"], "Connected through AgentPy.")
        self.assertEqual(done["tokens"], 7)
        service.save_preferences({"selected":agid,"drafts":{agid:"Keep this"}})
        count = len(service.snapshot()["events"])
        service = self.restart(service)
        state = service.snapshot()
        self.assertEqual(state["jobs"][0]["status"], "done")
        self.assertEqual(state["preferences"]["drafts"][agid], "Keep this")
        self.assertEqual(len(state["events"]), count)
        self.assertEqual(len(self.factory.prompts), 1)

    def test_creation_identity_and_computer_manifest(self):
        service = self.service()
        row = service.create_agent({"name":"Nova","role":"Research assistant"})
        service.update_agent(row["id"], {"name":"Nova","role":"Research lead"})
        job = service.submit(row["id"], {"text":"Inspect apps", "flow":"computer"})
        self.wait_job(service, job["id"])
        prompt = self.factory.prompts[-1]
        self.assertIn("Research lead", prompt)
        self.assertIn("Blindly4", prompt)
        self.assertIn("--require-value-path", prompt)
        self.assertIn("Inspect apps", prompt)
        self.assertEqual(service._agent(row["id"]).state["chat"][-1]["content"], "Connected through AgentPy.")

    def test_duplicate_submission_and_global_serialization(self):
        gate = self.factory.gate = threading.Event()
        self.addCleanup(gate.set)
        service = self.service()
        a = service.store.agents()[0]["id"]
        b = service.create_agent({"name":"Other","role":"Assistant"})["id"]
        first = service.submit(a, {"text":"First", "flow":"computer"})
        self.assertTrue(self.factory.started.wait(2))
        second = service.submit(b, {"text":"Second", "flow":"computer"})
        with self.assertRaises(APIError) as caught:
            service.submit(a, {"text":"Duplicate"})
        self.assertEqual(caught.exception.status, 409)
        state = service.snapshot()
        self.assertEqual(state["computer"]["owner"], a)
        self.assertEqual(next(j["status"] for j in state["jobs"] if j["id"] == second["id"]), "queued")
        gate.set()
        self.wait_job(service, first["id"])
        self.wait_job(service, second["id"])

    def test_failed_job_retry_and_dismiss(self):
        self.factory.fail = True
        service = self.service()
        agid = service.store.agents()[0]["id"]
        job = service.submit(agid, {"text":"Hello"})
        failed = self.wait_job(service, job["id"], "failed")
        self.assertIn("Scripted provider failure", failed["error"])
        self.factory.fail = False
        service.job_action(agid, job["id"], "retry")
        self.wait_job(service, job["id"])
        self.factory.fail = True
        job2 = service.submit(agid, {"text":"Again"})
        self.wait_job(service, job2["id"], "failed")
        service.job_action(agid, job2["id"], "cancel")
        self.wait_job(service, job2["id"], "cancelled")

    def test_running_job_recovers_without_replaying(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]["id"]
        job = service.submit(agid, {"text":"May already have acted", "flow":"computer"})
        agent = service._agent(agid)
        # Emulate a crash after the SDK reserved a call but before it committed a result.
        from datetime import datetime, timezone
        with agent.store.transaction() as state:
            agent._reserve(state, state["jobs"][0], agent.limits.tokens_per_loop, datetime.now(timezone.utc))
        service = self.restart(service)
        self.wait_job(service, job["id"], "interrupted")
        self.assertEqual(self.factory.prompts, [])
        service.job_action(agid, job["id"], "retry")
        self.wait_job(service, job["id"])

    def test_queued_job_is_recovered_after_restart(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]["id"]
        job = service.submit(agid, {"text":"Never started"})
        service = self.restart(service)
        self.wait_job(service, job["id"])
        self.assertEqual(len(self.factory.prompts), 1)

    def test_event_cursor_catches_up_without_gaps(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]["id"]
        for i in range(510):
            service.store.event(agid, "test", str(i))
        first = service.snapshot()
        second = service.snapshot(first["cursor"])
        self.assertEqual(len(first["events"]), 500)
        self.assertEqual(len(second["events"]), 11)
        self.assertEqual(second["cursor"], second["latest_cursor"])
        self.assertEqual(service.snapshot(second["cursor"])["events"], [])

    def test_single_host_and_input_validation(self):
        service = self.service()
        with self.assertRaises(RuntimeError):
            Service(self.directory.name)
        with self.assertRaises(APIError):
            service.create_agent({"name":"Group","role":"Team","kind":"group"})
        with self.assertRaises(APIError):
            service.save_preferences({"jobs":[{"status":"done"}]})
        with self.assertRaises(APIError):
            service.save_preferences({"workspaces":{"sapi":{"tabs":[1]}}})
        with self.assertRaises(APIError):
            service.submit("../../elsewhere", {"text":"Hello"})

    def test_http_creation_job_and_origin_boundary(self):
        service = self.service()
        server = Server(0, service)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_port

        def request(method, path, body=None, headers=None):
            connection = HTTPConnection("127.0.0.1", port, timeout=3)
            connection.request(method,path, json.dumps(body) if body is not None else None, headers or {})
            response = connection.getresponse()
            result = response.status, response.read()
            connection.close()
            return result

        headers = {"Content-Type":"application/json","X-Sapiens-Local":"1"}
        status, raw = request("POST","/api/agents",{"name":"HTTP","role":"Tester"},headers)
        self.assertEqual(status, 201)
        agid = json.loads(raw)["id"]
        status, raw = request("POST",f"/api/agents/{agid}/messages",{"text":"Hello"},headers)
        self.assertEqual(status, 202)
        self.wait_job(service, json.loads(raw)["id"])
        self.assertEqual(request("POST","/api/agents",{}, {**headers,"Origin":"https://evil.example"})[0], 403)
        self.assertEqual(request("POST","/api/agents",{}, {**headers,"Origin":"null"})[0], 403)
        self.assertEqual(request("GET","/api/state",headers={"Host":"evil.example"})[0], 403)
        self.assertEqual(request("POST","/api/agents",{})[0], 403)
        self.assertEqual(request("GET","/.sapiens4/corpora.sqlite3")[0], 404)
        self.assertEqual(request("GET","/.git/config")[0], 404)
        self.assertEqual(request("GET","/api/state?after=bad")[0], 400)
        self.assertEqual(request("GET","/workspace/app.js")[0], 200)

    def test_adapter_is_generated_and_cli_accepts_external_workdir(self):
        source = javascript()
        self.assertIn("state = makeInitialState(bootstrap)", source)
        self.assertNotIn("state = JSON.parse(localStorage.getItem(STORAGE))", source)
        from agentpy.interfaces import LLMSpec
        from unittest.mock import patch
        with patch("sapiens.runtime.codex_binary", return_value="/usr/local/bin/codex"):
            command = LocalFactory(workdir=Path(self.directory.name)).spawn(LLMSpec())._command("hello")
        self.assertIn("--skip-git-repo-check", command)
        self.assertIn(self.directory.name, command)


if __name__ == "__main__":
    unittest.main()

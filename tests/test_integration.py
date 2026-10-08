from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

from sapiens.corpora.host.assets import javascript
from sapiens.runtime.codex import CodexFactory
from sapiens.corpora.host.server import Server
from sapiens.corpora.host.service import APIError, Service


class ScriptedLLM:
    id = "test-session"

    def __init__(self, factory):
        self.factory = factory

    def complete(self, prompt):
        self.factory.prompts.append(prompt)
        self.factory.started.set()
        if self.factory.gate:
            if not self.factory.gate.wait(5):
                raise TimeoutError("Test gate timed out")
        if self.factory.fail:
            raise RuntimeError("Scripted provider failure")
        if getattr(self.factory, "on_complete", None):
            self.factory.on_complete(prompt)
        if getattr(self, 'role', None) == 'Assessing':
            return json.dumps(dict(event='FitsSpecialization', mode='Repl', reply='Connected through AgentPy.',
                                   reason='Immediate conversational response', evidence=[]))
        return "Connected through AgentPy."


class ScriptedFactory:
    def __init__(self, gate=None, fail=False):
        self.gate, self.fail = gate, fail
        self.started = threading.Event()
        self.prompts = []

    def builder(self, agid):
        return self

    def spawn(self, spec):
        llm = ScriptedLLM(self)
        llm.role = spec.role
        return llm


class IntegrationFixture(unittest.TestCase):
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
        service = Service(self.directory.name, factory_builder=self.factory.builder, pulse_clock=lambda: time.monotonic() * 20, **kwargs)
        self.services.append(service)
        return service


    def restart(self, service, **kwargs):
        service.close()
        self.services.remove(service)
        return self.service(**kwargs)

    def wait_turn(self, service, job_id, status="done"):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            turn = next(j for j in service.snapshot()["turns"] if j["id"] == job_id)
            if turn["status"] == status:
                return turn
            time.sleep(0.01)
        self.fail(f"Job did not reach {status}: {turn}")


class IntegrationTest(IntegrationFixture):
    def test_chat_projects_reply_and_survives_restart(self):
        service = self.service()
        agid = service.store.agents()[0]["id"]
        turn = service.submit(agid, {"text": "Hello"})
        done = self.wait_turn(service, turn["id"])
        self.assertEqual(done["output"], "Connected through AgentPy.")
        self.assertNotIn("tokens", done)
        service.save_preferences({"selected":agid,"drafts":{agid:"Keep this"}})
        service = self.restart(service)
        state = service.snapshot()
        self.assertEqual(state["turns"][0]["status"], "done")
        self.assertEqual(state["preferences"]["drafts"][agid], "Keep this")
        self.assertEqual(len(self.factory.prompts), 1)

    def test_creation_identity_and_computer_manifest(self):
        service = self.service()
        row = service.create_agent({"name":"Nova","role":"Research assistant"})
        service.update_agent(row["id"], {"name":"Nova","role":"Research lead"})
        turn = service.submit(row["id"], {"text":"Inspect apps", "flow":"computer"})
        self.wait_turn(service, turn["id"])
        prompt = self.factory.prompts[-1]
        self.assertIn("Research lead", prompt)
        self.assertIn('(' + next(a['face'] for a in service.store.agents() if a['id'] == row['id']) + ')', prompt)
        self.assertIn("Blindly4", prompt)
        self.assertIn("--require-value-path", prompt)
        self.assertIn("Inspect apps", prompt)
        self.assertEqual(service._agent(row["id"]).state["chat"][-1]["content"], "Connected through AgentPy.")

    def test_messages_continue_accumulating_per_sapi(self):
        gate = self.factory.gate = threading.Event()
        self.addCleanup(gate.set)
        service = self.service()
        a = service.store.agents()[0]["id"]
        b = service.create_agent({"name":"Other","role":"Assistant"})["id"]
        first = service.submit(a, {"text":"First", "flow":"computer"})
        self.assertTrue(self.factory.started.wait(2))
        second = service.submit(b, {"text":"Second", "flow":"computer"})
        additional = service.submit(a, {"text":"Another message"})
        self.assertEqual(additional['status'], 'queued')
        state = service.snapshot()
        self.assertIsNone(state["computer"]["owner"])
        self.wait_turn(service, second["id"], "running")
        gate.set()
        self.wait_turn(service, first["id"])
        self.wait_turn(service, second["id"])

    def test_failed_job_retry_and_dismiss(self):
        self.factory.fail = True
        service = self.service()
        agid = service.store.agents()[0]["id"]
        turn = service.submit(agid, {"text":"Hello"})
        failed = self.wait_turn(service, turn["id"], "failed")
        self.assertIn("Scripted provider failure", failed["error"])
        self.assertIsNone(failed["output"])
        self.factory.fail = False
        service.turn_action(agid, turn["id"], "retry")
        self.wait_turn(service, turn["id"])
        self.factory.fail = True
        job2 = service.submit(agid, {"text":"Again"})
        self.wait_turn(service, job2["id"], "failed")
        service.turn_action(agid, job2["id"], "cancel")
        self.wait_turn(service, job2["id"], "cancelled")

    def test_running_job_recovers_without_replaying(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]["id"]
        turn = service.submit(agid, {"text":"May already have acted", "flow":"computer"})
        agent = service._agent(agid)
        # Emulate a crash after a turn started but before it committed a result.
        with agent.transaction() as state:
            state["turns"][0]["status"] = "running"
        service = self.restart(service)
        self.wait_turn(service, turn["id"], "interrupted")
        self.assertEqual(self.factory.prompts, [])
        service.turn_action(agid, turn["id"], "retry")
        self.wait_turn(service, turn["id"])

    def test_queued_job_is_recovered_after_restart(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]["id"]
        turn = service.submit(agid, {"text":"Never started"})
        service = self.restart(service)
        self.wait_turn(service, turn["id"])
        self.assertEqual(len(self.factory.prompts), 1)

    def test_old_budgets_and_cached_results_are_inert_after_migration(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.registry.main)
        turn = service.submit(agent.agid, {'text': 'Continue'})['id']
        with agent.transaction() as state:
            state.update(schema_version=2, budgets={'old': {'spent': 999999999}},
                         limits={'tokens_per_call': 1}, budget_calendar={})
            state['turns'][0].update(status='budget_blocked', tokens=999, reserved=999)
        original = agent.path.read_bytes()
        workspace = service.workspace.root(agent)
        legacy = {agent.root / 'execution.json': '{"max_tools":1}',
                  workspace / 'recent-context.json': '[{"answer":"STALE_TOOL_RESULT"}]'}
        for path, value in legacy.items():
            path.write_text(value)
        service = self.restart(service)
        agent = service._agent(agent.agid)
        self.assertEqual(agent.state['schema_version'], 3)
        self.assertEqual((agent.root / 'legacy-state-v2.json').read_bytes(), original)
        self.assertEqual(agent.state['turns'][0]['status'], 'interrupted')
        self.assertNotIn('budgets', agent.state)
        self.assertEqual(self.factory.prompts, [])
        service.turn_action(agent.agid, turn, 'retry')
        self.wait_turn(service, turn)
        self.assertNotIn('STALE_TOOL_RESULT', self.factory.prompts[-1])
        self.assertFalse((agent.root / 'usage').exists())
        self.assertFalse((workspace / 'execution-clock.json').exists())
        for path, value in legacy.items():
            self.assertEqual(path.read_text(), value)

    def test_removed_log_panel_migrates_without_erasing_legacy_history(self):
        service = self.service(start_worker=False)
        agid = service.registry.main
        service.store.preferences(dict(panel='log', drafts={agid:'Keep this'}))
        with service.store.connect() as db:
            db.execute('CREATE TABLE events (id INTEGER PRIMARY KEY, detail TEXT)')
            db.execute("INSERT INTO events VALUES (1, 'Old activity')")
        service = self.restart(service, start_worker=False)
        state = service.snapshot()
        self.assertEqual(state['preferences']['panel'], 'chat')
        self.assertEqual(state['preferences']['drafts'][agid], 'Keep this')
        for field in ('events', 'cursor', 'latest_cursor'):
            self.assertNotIn(field, state)
        self.assertEqual(state['turns'], [])
        with service.store.connect() as db:
            self.assertEqual(db.execute('SELECT detail FROM events').fetchone()[0], 'Old activity')
        with self.assertRaises(APIError):
            service.save_preferences(dict(panel='log'))

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
        self.wait_turn(service, json.loads(raw)["id"])
        self.assertEqual(request("POST","/api/agents",{}, {**headers,"Origin":"https://evil.example"})[0], 403)
        self.assertEqual(request("POST","/api/agents",{}, {**headers,"Origin":"null"})[0], 403)
        self.assertEqual(request("GET","/api/state",headers={"Host":"evil.example"})[0], 403)
        self.assertEqual(request("POST","/api/agents",{})[0], 403)
        self.assertEqual(request("GET","/.sapiens4/corpora.sqlite3")[0], 404)
        self.assertEqual(request("GET","/.git/config")[0], 404)
        status, raw = request("GET", "/api/state")
        self.assertEqual(status, 200)
        self.assertNotIn("events", json.loads(raw))
        self.assertEqual(request("GET","/workspace/app.js")[0], 200)

    def test_adapter_is_generated_and_cli_accepts_external_workdir(self):
        source = javascript()
        self.assertIn("state = makeInitialState(bootstrap)", source)
        self.assertNotIn("state = JSON.parse(localStorage.getItem(STORAGE))", source)
        self.assertNotIn('globalThis.CorporaFixture', source)
        from sapiens.corpora.host.assets import index
        self.assertNotIn('fixtures/sapiens-cases.js', index())
        from sapiens.runtime.contracts import LLMSpec
        from unittest.mock import patch
        with patch("sapiens.runtime.codex.codex_binary", return_value="/usr/local/bin/codex"):
            command = CodexFactory(workdir=Path(self.directory.name)).spawn(LLMSpec())._command("hello")
        self.assertIn("--skip-git-repo-check", command)
        self.assertIn(self.directory.name, command)


if __name__ == "__main__":
    unittest.main()

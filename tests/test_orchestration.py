from datetime import datetime, timedelta, timezone
import json
from http.client import HTTPConnection
import threading

from test_integration import IntegrationFixture, ScriptedFactory, ScriptedLLM
from sapiens.server import Server
from sapiens.service import APIError


class MemoryLLM(ScriptedLLM):
    usage = {"input_tokens": 17000, "output_tokens": 100}

    def complete(self, prompt):
        super().complete(prompt)
        return json.dumps({'upsert': [{'kind': 'preference', 'content': 'Use concise answers',
                            'evidence': 'User request', 'salience': 0.7, 'tags': []}], 'forget': []})


class MemoryFactory(ScriptedFactory):
    def spawn(self, spec):
        return MemoryLLM(self) if spec.role.startswith('memory_') else ScriptedLLM(self)


class OrchestrationTest(IntegrationFixture):
    def test_saved_manager_and_schedule_survive_restart(self):
        service = self.service(start_worker=False)
        director = service.store.agents()[0]['id']
        nova = service.create_agent({'name': 'Nova', 'role': 'Researcher'})['id']
        control = service.orchestration.control
        result = control(nova, {'op': 'manager', 'manager': director})
        self.assertEqual(result['manager'], director)
        control(director, {'op': 'schedule', 'minutes': 5, 'monitor_team': True})
        with self.assertRaises(ValueError):
            control(director, {'op': 'manager', 'manager': nova})
        with self.assertRaises(APIError):
            control(nova, {'op': 'manager', 'manager': 'Missing'})
        for minutes in (0, True, 1.5, 1441):
            with self.assertRaises(APIError):
                control(director, {'op': 'schedule', 'minutes': minutes})
        service = self.restart(service, start_worker=False)
        state = service.snapshot()['orchestration']
        self.assertEqual(state[nova]['manager'], director)
        self.assertEqual(state[director]['schedule']['minutes'], 5)
        self.assertTrue(state[director]['schedule']['monitor_team'])
        service.orchestration.prepare(service._agent(nova))
        facts = json.loads(service._agent(nova).manifests['host-facts'])
        self.assertEqual(next(a for a in facts['team'] if a['id'] == nova)['manager'], director)

    def test_idle_heartbeat_checks_team_without_llm_and_pause(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]['id']
        service.orchestration.control(agid, {'op': 'schedule', 'minutes': 5, 'monitor_team': True})
        start = datetime.fromisoformat(service.snapshot()['orchestration'][agid]['schedule']['next_check'])
        service.scheduled(start - timedelta(seconds=1))
        self.assertIsNone(service._agent(agid).state['next_awake'])
        service.scheduled(start)
        schedule = service.snapshot()['orchestration'][agid]['schedule']
        self.assertEqual(schedule['next_check'], (start + timedelta(minutes=5)).isoformat())
        self.assertEqual(service._agent(agid).state['next_awake'], schedule['next_check'])
        self.assertEqual(schedule['team_checked_at'], start.isoformat())
        service.scheduled(start + timedelta(minutes=20))  # One catch-up, not four replays.
        events = service.snapshot()['events']
        self.assertEqual(sum(e['kind'] == 'heartbeat' for e in events), 2)
        self.assertEqual(sum(e['kind'] == 'team_check' for e in events), 1)
        self.assertEqual(self.factory.prompts, [])
        service.orchestration.control(agid, {'op': 'schedule', 'enabled': False})
        service.scheduled(start + timedelta(days=2))
        self.assertEqual(sum(e['kind'] == 'heartbeat' for e in service.snapshot()['events']), 2)

    def test_due_task_runs_once_and_result_is_visible(self):
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]['id']
        control = service.orchestration.control
        task = control(agid, {'op': 'task', 'title': 'Evaluate the available evidence',
                             'due': '2026-01-01T00:00:00+00:00'})['task_id']
        start = datetime.now(timezone.utc) + timedelta(minutes=11)
        service.scheduled(start)
        jobs = service.snapshot()['jobs']
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]['flow'], 'reason')
        self.assertEqual(jobs[0]['status'], 'done')
        self.assertEqual(jobs[0]['output'], 'Connected through AgentPy.')
        service.scheduled(start + timedelta(minutes=11))
        self.assertEqual(len(service.snapshot()['jobs']), 1)
        control(agid, {'op': 'finish_task', 'id': task})
        self.assertEqual(service._agent(agid).state['tasks'], [])

    def test_memory_learning_commits_after_chat_and_persists(self):
        self.factory = MemoryFactory()
        service = self.service(start_worker=False)
        agid = service.store.agents()[0]['id']
        job = service.submit(agid, {'text': 'Use concise answers'})
        service.orchestration.control(agid, {'op': 'consolidate'})
        service.scheduled()  # Must wait for the unresolved conversation.
        self.assertEqual(self.factory.prompts, [])
        service = self.restart(service)
        self.wait_job(service, job['id'])
        import time
        deadline = time.monotonic() + 5
        while not service._agent(agid).memx and time.monotonic() < deadline:
            time.sleep(0.02)
        agent = service._agent(agid)
        self.assertEqual(agent.memx[0]['content'], 'Use concise answers')
        self.assertEqual(agent.state['learned_revision'], agent.state['chat_revision'])
        self.assertIn('Connected through AgentPy.', self.factory.prompts[-1])
        service = self.restart(service, start_worker=False)
        self.assertEqual(len(service._agent(agid).memx), 1)
        self.assertFalse(service.orchestration.settings(service._agent(agid))['consolidate_requested'])

    def test_stopped_job_is_not_retried_by_timer(self):
        self.factory.fail = True
        service = self.service()
        agid = service.store.agents()[0]['id']
        job = service.submit(agid, {'text': 'Fail'})
        self.wait_job(service, job['id'], 'failed')
        service.scheduled(datetime.now(timezone.utc) + timedelta(days=1))
        self.assertEqual(len(self.factory.prompts), 1)
        self.assertEqual(service.snapshot()['jobs'][0]['status'], 'failed')

    def test_http_control_is_wired_and_rejects_cross_origin(self):
        service = self.service(start_worker=False)
        server = Server(0, service)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        agid = service.store.agents()[0]['id']
        config = json.loads((service.root / 'workspaces' / agid / 'host-control.json').read_text())
        self.assertIn(str(server.server_port), config['url'])
        conn = HTTPConnection('127.0.0.1', server.server_port)
        headers = {'Content-Type': 'application/json', 'X-Sapiens-Local': '1'}
        path = f'/api/agents/{agid}/control'
        conn.request('POST', path, json.dumps({'op': 'schedule', 'minutes': 5}), headers)
        response = conn.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(response.read())['schedule']['minutes'], 5)
        conn.request('POST', path, json.dumps({'op': 'manager', 'manager': None}),
                     {**headers, 'Origin': 'https://evil.example'})
        response = conn.getresponse()
        self.assertEqual(response.status, 403)
        response.read()
        conn.close()
        service.orchestration.prepare(service._agent(agid))
        prompt = service._agent(agid).config.roles['conversation'].prompt
        self.assertIn('check its JSON result before confirming', prompt)
        self.assertNotIn('Do not use tools', prompt)

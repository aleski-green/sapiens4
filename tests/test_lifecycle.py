"""Chief-owned retirement stops work without deleting an agent's identity/state."""
import asyncio
from datetime import datetime, timedelta, timezone
from http.client import HTTPConnection
import json
from pathlib import Path
import threading
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.server import Server
from sapiens.validation import APIError


class LifecycleTest(IntegrationFixture):
    def team(self):
        service = self.service(start_worker=False)
        chief = service.hierarchy.main
        child = service.create_agent(dict(name='Seneca', role='Researcher'))['id']
        return service, chief, child

    def test_retire_and_rehire_preserve_history_files_identity_and_preferences(self):
        service, chief, child = self.team()
        control = service.orchestration.control
        job = service.submit(child, dict(text='Remember the research'))['id']
        agent = service._agent(child)
        asyncio.run(agent.run())
        service._sync(agent)
        history = agent.state['chat']
        memory = agent.memx
        artifact = control(child, dict(op='artifact_save', name='research.md', content='# Findings'))['artifact']
        task = control(chief, dict(op='task', target=child, title='Preserve this planned task'))['task_id']
        recurring = control(child, dict(op='recurring_job', title='Check research', prompt='Inspect notes', minutes=30))['recurring_job']
        service.save_preferences(dict(selected=child, drafts={child:'Keep my draft'}))
        retired = control(chief, dict(op='retire_agent', target='Seneca', reason='Role not currently needed'))
        self.assertTrue(retired['retired'])
        self.assertTrue(retired['saved'])
        self.assertFalse(control(chief, dict(op='retire_agent', target=child))['changed'])
        service = self.restart(service, start_worker=False)
        control = service.orchestration.control
        status = control(chief, dict(op='status'))
        self.assertNotIn(child, [r['id'] for r in status['team']])
        self.assertEqual(status['retired_team'][0]['id'], child)
        self.assertEqual(status['retired_team'][0]['reason'], 'Role not currently needed')
        self.assertTrue(next(r for r in service.snapshot()['agents'] if r['id'] == child)['retired'])
        self.assertEqual(control(chief, dict(op='status', target=child))['workspace']['artifacts'][0]['reference'], artifact['reference'])
        rehired = control(chief, dict(op='rehire_agent', target='Seneca'))
        self.assertEqual(rehired['id'], child)
        self.assertFalse(rehired['retired'])
        self.assertFalse(control(chief, dict(op='rehire_agent', target=child))['changed'])
        service = self.restart(service, start_worker=False)
        agent = service._agent(child)
        self.assertEqual(len(service.store.agents()), 2)
        self.assertEqual(agent.state['chat'], history)
        self.assertEqual(agent.memx, memory)
        self.assertEqual(agent.state['tasks'][0]['id'], task)
        self.assertEqual(Path(artifact['path']).read_text(), '# Findings')
        self.assertEqual(service.store.read_preferences()['drafts'][child], 'Keep my draft')
        self.assertEqual(next(j for j in service.snapshot()['jobs'] if j['id'] == job)['output'], 'Connected through AgentPy.')
        self.assertFalse(service.lifecycle.retired(agent))
        self.assertFalse(service.orchestration.settings(agent)['enabled'])
        self.assertEqual(service.work.read(agent)[0]['id'], recurring['id'])
        self.assertFalse(service.work.read(agent)[0]['enabled'])
        self.assertEqual(service.orchestration.status(service._agent(chief))['retired_team'], [])

    def test_only_chief_can_change_lifecycle_and_cannot_retire_itself(self):
        service, chief, child = self.team()
        other = service.create_agent(dict(name='Nova', role='Assistant'))['id']
        for caller, op, target, code in [(child, 'retire_agent', other, 403),
                                       (other, 'rehire_agent', child, 403),
                                       (chief, 'retire_agent', chief, 400)]:
            with self.subTest(caller=caller, op=op):
                with self.assertRaises(APIError) as error:
                    service.orchestration.control(caller, dict(op=op, target=target))
                self.assertEqual(error.exception.status, code)
        self.assertEqual(service.lifecycle.catalog(), [])
        for data in [dict(op='retire_agent'), dict(op='retire_agent', target='Missing'),
                     dict(op='retire_agent', target=child, reason=[]),
                     dict(op='retire_agent', target=child, reason='x'*501)]:
            with self.assertRaises(APIError):
                service.orchestration.control(chief, data)
        self.assertEqual(service.lifecycle.catalog(), [])

    def test_busy_agents_and_active_managers_must_be_resolved_first(self):
        service, chief, child = self.team()
        control = service.orchestration.control
        report = service.create_agent(dict(name='Nova', role='Assistant', manager=child))['id']
        with self.assertRaisesRegex(APIError, 'direct reports'):
            control(chief, dict(op='retire_agent', target=child))
        control(chief, dict(op='retire_agent', target=report))
        job = service.submit(child, dict(text='Queued work'))['id']
        for state in ['queued', 'running']:
            with service._agent(child).store.transaction() as saved:
                saved['jobs'][0]['status'] = state
            with self.assertRaisesRegex(APIError, 'Finish or cancel'):
                control(chief, dict(op='retire_agent', target=child))
        with service._agent(child).store.transaction() as saved:
            saved['jobs'][0]['status'] = 'queued'
        service.job_action(child, job, 'cancel')
        service._background.add(child)
        with self.assertRaisesRegex(APIError, 'Finish or cancel'):
            control(chief, dict(op='retire_agent', target=child))
        service._background.remove(child)
        control(chief, dict(op='retire_agent', target=child))
        control(chief, dict(op='rehire_agent', target=report))
        self.assertEqual(service._agent(report).corpora.directory()[report]['parent'], chief)

    def test_retired_sapis_cannot_receive_run_or_resume_work(self):
        service, chief, child = self.team()
        control = service.orchestration.control
        task = control(chief, dict(op='task', target=child, title='Due work', due='2020-01-01T00:00:00+00:00'))['task_id']
        control(child, dict(op='artifact_save', name='saved.md', content='Retain this'))
        job = service._agent(child).submit('task', 'Blocked work')
        with service._agent(child).store.transaction() as state:
            state['jobs'][0]['status'] = 'budget_blocked'
        control(chief, dict(op='retire_agent', target=child))
        mutations = [dict(op='task', target=child, title='New work'),
                     dict(op='run_task', target=child, id=task),
                     dict(op='recurring_job', target=child, title='New job', prompt='Work', minutes=10),
                     dict(op='manager', target=child, manager=None),
                     dict(op='create_agent', name='Seneca', role='Researcher')]
        for mutation in mutations:
            with self.subTest(op=mutation['op']):
                with self.assertRaisesRegex(APIError, 'retired'):
                    control(chief, mutation)
        for mutation in [dict(op='schedule', enabled=True), dict(op='consolidate'),
                         dict(op='batch', operations=[dict(op='schedule', enabled=True)])]:
            with self.assertRaisesRegex(APIError, 'retired'):
                control(child, mutation)
        with self.assertRaisesRegex(APIError, 'retired'):
            service.submit(child, dict(text='Do work'))
        with self.assertRaisesRegex(APIError, 'retired'):
            service.job_action(child, job, 'retry')
        with self.assertRaisesRegex(APIError, 'retired'):
            service.update_agent(child, dict(name='Seneca', role='Changed role'))
        self.assertEqual(control(child, dict(op='artifact_read', name='saved.md'))['content'], 'Retain this')
        self.assertEqual(control(child, dict(op='workspace_open', artifact='saved.md'))['tab']['artifact'], 'saved.md')
        service = self.restart(service, start_worker=False)
        agent = service._agent(child)
        # Even stale scheduling flags must not bypass the retired flag.
        settings = service.orchestration.settings(agent)
        settings.update(enabled=True, next_check=None, consolidate_requested=True)
        service.orchestration.save(agent, settings)
        with patch.object(service._agent(chief), 'tick'), patch.object(agent, 'run') as run, patch.object(agent, 'tick') as tick:
            service.orchestration.control(chief, dict(op='schedule', enabled=False))
            service.scheduled(datetime.now(timezone.utc) + timedelta(days=1))
        run.assert_not_called()
        tick.assert_not_called()
        self.assertEqual(self.factory.prompts, [])
        self.assertEqual(agent.state['jobs'][0]['status'], 'budget_blocked')
        self.assertIsNone(agent.state['tasks'][0].get('job'))

    def test_host_http_receipts_and_manifests_support_chief_lifecycle(self):
        service, chief, child = self.team()
        server = Server(0, service)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        connection = HTTPConnection('127.0.0.1', server.server_port)
        self.addCleanup(connection.close)
        headers = {'Content-Type':'application/json', 'X-Sapiens-Local':'1'}
        for caller, op, expected in [(child, 'retire_agent', 403), (chief, 'retire_agent', 200),
                                     (chief, 'rehire_agent', 200)]:
            connection.request('POST', f'/api/agents/{caller}/control', json.dumps(dict(op=op, target=child)), headers)
            response = connection.getresponse()
            payload = json.loads(response.read())
            self.assertEqual(response.status, expected, payload)
            if expected == 200:
                self.assertTrue(payload['saved'])
        service.orchestration.control(chief, dict(op='retire_agent', target=child))
        service.orchestration.prepare(service._agent(chief))
        manifests = service._agent(chief).manifests
        self.assertIn('rehire_agent', manifests['host-control'])
        self.assertEqual(json.loads(manifests['host-facts'])['retired_team'][0]['id'], child)

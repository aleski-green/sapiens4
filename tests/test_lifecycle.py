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
        turn = service.submit(child, dict(text='Remember the research'))['id']
        agent = service._agent(child)
        asyncio.run(agent.run())
        service._sync(agent)
        history = agent.state['chat']
        notes = service.workspace.root(agent) / "Notes.md"
        notes.write_text("Keep these findings")
        file = service.workspace.root(agent) / 'research.md'
        file.write_text('# Findings')
        tab = control(child, dict(op='workspace_open', path=str(file)))['workspace']['tabs'][0]
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
        self.assertEqual(control(chief, dict(op='status', target=child))['workspace']['tabs'][0]['path'], str(file))
        rehired = control(chief, dict(op='rehire_agent', target='Seneca'))
        self.assertEqual(rehired['id'], child)
        self.assertFalse(rehired['retired'])
        self.assertFalse(control(chief, dict(op='rehire_agent', target=child))['changed'])
        service = self.restart(service, start_worker=False)
        agent = service._agent(child)
        self.assertEqual(len(service.store.agents()), 2)
        self.assertEqual(agent.state['chat'], history)
        self.assertEqual(notes.read_text(), "Keep these findings")
        self.assertEqual(file.read_text(), '# Findings')
        self.assertEqual(service.store.read_preferences()['drafts'][child], 'Keep my draft')
        self.assertEqual(next(j for j in service.snapshot()['turns'] if j['id'] == turn)['output'], 'Connected through AgentPy.')
        self.assertFalse(service.lifecycle.retired(agent))
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
        turn = service.submit(child, dict(text='Queued work'))['id']
        for state in ['queued', 'running']:
            with service._agent(child).store.transaction() as saved:
                saved['turns'][0]['status'] = state
            with self.assertRaisesRegex(APIError, 'Finish or cancel'):
                control(chief, dict(op='retire_agent', target=child))
        with service._agent(child).store.transaction() as saved:
            saved['turns'][0]['status'] = 'queued'
        service.turn_action(child, turn, 'cancel')
        control(chief, dict(op='retire_agent', target=child))
        control(chief, dict(op='retire_agent', target=child))
        control(chief, dict(op='rehire_agent', target=report))
        self.assertEqual(service._agent(report).corpora.directory()[report]['parent'], chief)

    def test_retired_sapis_cannot_receive_run_or_resume_work(self):
        service, chief, child = self.team()
        control = service.orchestration.control
        file = service.workspace.root(service._agent(child)) / 'saved.md'
        file.write_text('Retain this')
        turn = service._agent(child).tell('Blocked work')
        with service._agent(child).store.transaction() as state:
            state['turns'][0]['status'] = 'interrupted'
        control(chief, dict(op='retire_agent', target=child))
        with self.assertRaisesRegex(APIError, 'retired'):
            service.submit(child, dict(text='Do work'))
        with self.assertRaisesRegex(APIError, 'retired'):
            service.turn_action(child, turn, 'retry')
        with self.assertRaisesRegex(APIError, 'retired'):
            service.update_agent(child, dict(name='Seneca', role='Changed role'))
        self.assertEqual(file.read_text(), 'Retain this')
        service = self.restart(service)
        self.assertEqual(self.factory.prompts, [])
        self.assertEqual(service._agent(child).state['turns'][0]['status'], 'interrupted')

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

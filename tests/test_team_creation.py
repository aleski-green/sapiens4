"""Exercise the real agent-facing HTTP command, storage, and task scheduler."""
from datetime import datetime, timedelta
import asyncio
import json
import shlex
from pathlib import Path
import subprocess
import sys
import threading

from test_integration import IntegrationFixture
from sapiens.paths import ROOT
from sapiens.corpora.host.server import Server
from sapiens.validation import APIError


class TeamCreationTest(IntegrationFixture):

    def test_generated_commands_run_from_the_sapi_workspace(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.registry.main)
        server = Server(0, service)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            command = shlex.split(agent.manifests['host-control'].splitlines()[0][4:].split(" 'JSON'", 1)[0])
            result = subprocess.run([*command, '{"op":"status"}'], cwd=service.workspace.root(agent),
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['self_id'], agent.agid)
            computer = shlex.split(agent.manifests['computer-use'].splitlines()[0].partition(': ')[2])
            result = subprocess.run(computer, cwd=service.workspace.root(agent),
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('Usage:', json.loads(result.stdout)['error'])
            self.assertFalse((service.workspace.root(agent) / '.computer-used').exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_invalid_creation_and_targets_do_not_create_phantom_agents(self):
        service = self.service(start_worker=False)
        control = service.orchestration.control
        main = service.registry.main
        child = control(main, dict(op='create_agent', name='Writer', role='Writing'))['agent']['id']
        for caller, data in [
            (child, dict(op='create_agent', name='Extra', role='Research')),
            (main, dict(op='create_agent', name='Writer', role='Different')),
            (main, dict(op='create_agent', name='Bad Name', role='Research')),
            (main, dict(op='create_agent', name='Extra', role='Research', manager='Missing')),
            (main, dict(op='recurring_job', target='Missing', title='Draft', prompt='Draft', minutes=60)),
        ]:
            with self.assertRaises(APIError):
                control(caller, data)
        self.assertEqual(len(service.store.agents()), 2)

    def test_batch_creates_team_and_reports_partial_failure(self):
        service = self.service(start_worker=False)
        main = service.registry.main
        operations = [dict(op='create_agent', name=name, role=name) for name in ['Researcher', 'Writer', 'Reviewer']]
        result = service.orchestration.control(main, dict(op='batch', operations=operations))
        self.assertTrue(result['saved'])
        self.assertEqual(len(result['results']), 3)
        result = service.orchestration.control(main, dict(op='batch', operations=[
            dict(op='create_agent', name='Analyst', role='Analysis'),
            dict(op='create_agent', name='Analyst', role='Conflicting'),
            dict(op='create_agent', name='Unreached', role='Analysis')]))
        self.assertFalse(result['saved'])
        self.assertTrue(result['partial'])
        self.assertEqual(result['failed_index'], 1)
        self.assertEqual(len(result['results']), 1)
        self.assertNotIn('Unreached', [r['name'] for r in service.store.agents()])
        with self.assertRaises(APIError):
            service.orchestration.control(main, dict(op='batch', operations=[dict(op='batch', operations=[])]))
        with self.assertRaises(APIError):
            service.orchestration.control(main, dict(op='task', target='Analyst', title='Test', start='yes'))

"""Exercise the real agent-facing HTTP command, storage, and task scheduler."""
from datetime import datetime, timedelta
import asyncio
import json
from pathlib import Path
import subprocess
import sys
import threading

from test_integration import IntegrationFixture
from sapiens.paths import ROOT
from sapiens.server import Server
from sapiens.validation import APIError


class TeamCreationTest(IntegrationFixture):
    def test_host_command_creates_three_roles_assigns_and_runs_work(self):
        service = self.service(start_worker=False)
        server = Server(0, service)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        main = service.hierarchy.main
        config = service.root / 'workspaces' / main / 'host-control.json'

        def call(**payload):
            result = subprocess.run([sys.executable, str(ROOT / 'sapiens/control.py'),
                str(config), json.dumps(payload)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)

        children = []
        for name, role in [('Researcher', 'Research'), ('Writer', 'Writing'), ('Reviewer', 'Review')]:
            receipt = call(op='create_agent', name=name, role=role)
            child = receipt['agent']['id']
            children.append(child)
            self.assertTrue(receipt['created'])
            self.assertFalse(call(op='create_agent', name=name, role=role)['created'])
            self.assertTrue((service.root / 'workspaces' / child / 'host-control.json').exists())
            task = call(op='task', target=child, title='Prepare a ' + role + ' plan')
            run = call(op='run_task', target=child, id=task['task_id'])
            self.assertEqual(service._agent(child).state['tasks'][0]['job'], run['run_id'])
            self.assertEqual(service._agent(child).state['jobs'][0]['status'], 'queued')
        row = call(op='recurring_job', target=children[1], title='Daily draft',
                   prompt='Generate a new draft each day', minutes=1440,
                   watch={'mode': 'always'})['recurring_job']
        self.assertEqual(service.work.read(service._agent(main)), [])
        self.assertEqual(len(service.store.agents()), 4)
        server.shutdown()
        server.server_close()
        service = self.restart(service, start_worker=False)
        for child in children:
            self.assertEqual(service._agent(child).corpora.directory()[child]['parent'], main)
            asyncio.run(service._agent(child).run())
            service._sync(service._agent(child))
            self.assertEqual(service._agent(child).state['jobs'][0]['status'], 'done')
        owner = service._agent(children[1])
        self.assertEqual(service.work.read(owner)[0]['id'], row['id'])
        self.ready_strategy(service, owner, row)
        service.scheduled(datetime.fromisoformat(row['next_run']))
        runs = service.work.read(owner)[0]['runs']
        self.assertEqual(len(runs), 1)
        service.scheduled(datetime.fromisoformat(row['next_run']))
        self.assertEqual(len(service.work.read(owner)[0]['runs']), 1)

    def test_invalid_creation_and_targets_do_not_create_phantom_agents(self):
        service = self.service(start_worker=False)
        control = service.orchestration.control
        main = service.hierarchy.main
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
        self.assertEqual(service.work.read(service._agent(main)), [])

    def test_batch_starts_assigned_tasks_and_reports_partial_failure(self):
        service = self.service(start_worker=False)
        main = service.hierarchy.main
        operations = []
        for name in ['Researcher', 'Writer', 'Reviewer']:
            operations += [dict(op='create_agent', name=name, role=name),
                           dict(op='task', target=name, title='Outline approach', start=True)]
        operations.append(dict(op='recurring_job', target='Writer', title='Daily tip',
                               prompt='Generate a new tip', minutes=1440, watch={'mode':'always'}))
        result = service.orchestration.control(main, dict(op='batch', operations=operations))
        self.assertTrue(result['saved'])
        self.assertEqual(len(result['results']), 7)
        for index in [1, 3, 5]:
            self.assertIn('run_id', result['results'][index])
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
        self.assertEqual(service.orchestration.resolve('Analyst').state['tasks'], [])

    def test_request_origin_and_chief_dismissal_survive_restart(self):
        service = self.service(start_worker=False)
        chief = service.hierarchy.main
        control = service.orchestration.control
        origin = control(chief, dict(op='create_agent', name='Writer', role='Writing'))['agent']['id']
        request = control(origin, dict(op='request_agent', context='Need Researcher for source checks; prepare a source list once.'))
        task_id = request['task_id']
        task = service._agent(chief).state['tasks'][0]
        self.assertEqual(task['assigned_by'], origin)
        self.assertIn('@Writer', task['title'])
        self.assertIsNotNone(task['due'])
        self.assertEqual(service.tasks.notices()[0]['assigned_by'], origin)
        with self.assertRaises(APIError):
            control(origin, dict(op='dismiss_task', id=task_id, reason='Not my task'))
        run = control(chief, dict(op='run_task', id=task_id))['run_id']
        result = control(chief, dict(op='dismiss_task', id=task_id, reason='Existing research coverage is sufficient.'))
        self.assertEqual(result['status'], 'dismissed')
        self.assertEqual(service._agent(chief).state['tasks'], [])
        self.assertEqual(next(j for j in service._agent(chief).state['jobs'] if j['id']==run)['status'], 'cancelled')
        service = self.restart(service, start_worker=False)
        task = next(t for t in service.tasks.catalog() if t['id']==task_id)
        self.assertEqual(task['status'], 'dismissed')
        self.assertEqual(task['assigned_by'], origin)
        update = next(u for u in service.tasks.updates() if u['kind']=='dismissed')
        self.assertEqual(update['assigned_by'], origin)
        self.assertIn('Existing research', update['text'])

    def test_chief_can_dismiss_during_its_review(self):
        service = self.service(start_worker=False)
        chief = service.hierarchy.main
        origin = service.create_agent(dict(name='Writer', role='Writing'))['id']
        request = service.orchestration.control(origin, dict(op='request_agent', context='Propose another writer.'))
        self.factory.on_complete = lambda prompt: service.orchestration.control(chief, dict(
            op='dismiss_task', id=request['task_id'], reason='Existing writer can do this.'))
        service.scheduled()
        jobs = service._agent(chief).state['jobs']
        self.assertEqual(jobs[0]['status'], 'done')
        self.assertEqual(service._agent(chief).state['tasks'], [])
        self.assertEqual(service.tasks.catalog()[0]['status'], 'dismissed')

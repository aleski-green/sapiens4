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

    def test_batch_creates_team_and_reports_partial_failure(self):
        service = self.service(start_worker=False)
        main = service.hierarchy.main
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

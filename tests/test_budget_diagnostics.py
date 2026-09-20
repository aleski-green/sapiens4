import asyncio
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.execution import read
from sapiens.runtime import LocalLLM
from sapiens.service import APIError
from sapiens.usage import save_record
from agentpy.interfaces import LLMSpec


class DiagnosticsTest(IntegrationFixture):
    def test_diagnostics_classify_and_paginate_without_model_calls(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        other = service.create_agent({'name': 'Nova', 'role': 'Assistant'})['id']
        timeout = agent.submit('chat', 'Investigate')
        blocked = agent.submit('learning')
        limited = agent.submit('chat', 'Check')
        with agent.store.transaction() as state:
            for job in state['jobs']:
                if job['id'] == timeout:
                    job.update(status='cancelled', error='TimeoutError: Codex exceeded 120s\nCLI noise')
                elif job['id'] == blocked:
                    job.update(status='budget_blocked', error='Budget allowance unavailable')
                else:
                    job.update(status='failed', error='RuntimeError: Tool-step limit reached')
            state['budgets'][agent._sprint(datetime.now(timezone.utc))] = dict(spent=850000, reserved=0)
        save_record(agent, dict(id='unknown-timeout', job=timeout, flow='chat', status='failed',
            time=datetime.now(timezone.utc).isoformat(), usage=None, budget_units=100000))
        save_record(agent, dict(id='active', job='still-running', status='running',
            time=datetime.now(timezone.utc).isoformat(), usage=None))
        control = service.orchestration.control
        first = control(other, dict(op='budget_diagnostics', target=agent.agid, limit=1))
        self.assertEqual(first['issue_counts'], dict(timeout=1, budget_allowance=1, tool_limit=1))
        self.assertEqual(first['total_issues'], 3)
        self.assertEqual(first['next_offset'], 1)
        self.assertEqual(first['issues'][0]['status'], 'cancelled')
        self.assertNotIn('CLI noise', first['issues'][0]['error'])
        self.assertEqual(first['agents'][0]['unknown_usage_attempts'], 1)
        self.assertEqual(first['agents'][0]['fallback_units_retained_history'], 100000)
        self.assertEqual(first['agents'][0]['admission']['learning']['shortfall_units'], 150000)
        self.assertEqual(first['agents'][0]['admission']['chat']['shortfall_units'], 0)
        second = control(other, dict(op='budget_diagnostics', target=agent.agid, offset=1, limit=2))
        self.assertEqual(len(second['issues']), 2)
        self.assertIsNone(second['next_offset'])
        self.assertEqual(len(control(other, dict(op='budget_diagnostics'))['agents']), 2)
        self.assertEqual(self.factory.prompts, [])
        for extra in ({'limit': 21}, {'offset': -1}, {'limit': True}):
            with self.assertRaises(APIError):
                control(other, dict(op='budget_diagnostics', **extra))

    def test_clock_and_deadline_prompt_finish_without_an_extra_call(self):
        root = Path(self.directory.name)
        llm = LocalLLM(spec=LLMSpec(role='conversation'), workdir=root, event_sink=lambda _: None)
        llm.max_tools = 16
        def complete(instance, prompt):
            self.assertIn('120 seconds total', prompt)
            self.assertIn('Stop discovery by', prompt)
            self.assertIn('Save useful findings incrementally', prompt)
            self.assertEqual(read(root)['phase'], 'investigate')
            instance._clock['finish_by'] = (datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()
            instance._consume_event(dict(type='item.completed', item=dict(id='a', type='command_execution', command='read')))
            self.assertEqual(read(root)['tools_remaining'], 15)
            self.assertEqual(read(root)['phase'], 'save_and_finish')
            return 'Saved findings'
        with patch('sapiens.runtime.CodexLLM.complete', complete):
            self.assertEqual(llm.complete('Investigate'), 'Saved findings')
        self.assertFalse(read(root)['active'])
        self.assertEqual(read(root)['phase'], 'stopped')

    def test_timeout_keeps_saved_artifact_as_warning_with_unknown_usage(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        root = service.workspace.root(agent)
        class Factory:
            def spawn(self, spec):
                return LocalLLM(spec=spec, workdir=root, event_sink=lambda _: None)
        agent.factory = Factory()
        def complete(instance, prompt):
            service.workspace.save(agent, dict(name='budget-findings.md', content='# Partial findings'))
            raise TimeoutError('Codex exceeded 120s')
        job = service.submit(agent.agid, dict(text='Inspect budgets'))['id']
        with patch('sapiens.runtime.CodexLLM.complete', complete):
            asyncio.run(agent.run())
        service._sync(agent)
        result = next(j for j in service.snapshot()['jobs'] if j['id'] == job)
        self.assertEqual(result['status'], 'warning')
        self.assertIn('@art-md', result['output'])
        self.assertIn('time limit', result['output'])
        self.assertIn('unverified', result['output'])
        diagnostic = service.orchestration.control(agent.agid, dict(op='budget_diagnostics'))
        self.assertEqual(diagnostic['issues'][0]['category'], 'timeout')
        self.assertEqual(diagnostic['issues'][0]['unknown_usage_attempts'], 1)
        self.assertEqual(read(root)['phase'], 'stopped')

    def test_timeout_without_artifact_stays_failed(self):
        llm = LocalLLM(spec=LLMSpec(role='conversation'), workdir=Path(self.directory.name), event_sink=lambda _: None)
        with patch('sapiens.runtime.CodexLLM.complete', side_effect=TimeoutError('Codex exceeded 120s')):
            with self.assertRaises(TimeoutError):
                llm.complete('Inspect budgets')
        self.assertIsNone(llm.warning)
        self.assertEqual(read(self.directory.name)['phase'], 'stopped')

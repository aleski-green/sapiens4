import asyncio
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.experience import evidence, tool_failure
from sapiens.memory import fingerprint
from sapiens.runtime import CodexLLM, LocalLLM
from sapiens.sdk import LLMSpec
from sapiens import workflow


class ExperienceTest(IntegrationFixture):
    def test_failed_run_survives_restart_and_reaches_next_prompt(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        self.factory.fail = True
        job = service.submit(agent.agid, {'text': 'Research a profile'})['id']
        asyncio.run(agent.run())
        service._sync(agent)
        service = self.restart(service, start_worker=False)
        self.factory.fail = False
        agent = service._agent(service.hierarchy.main)
        service.orchestration.prepare(agent)
        service.submit(agent.agid, {'text': 'Try a different approach'})
        asyncio.run(agent.run())
        self.assertIn(job, self.factory.prompts[-1])
        self.assertIn('execution_failed', self.factory.prompts[-1])
        self.assertIn('Historical execution failures', self.factory.prompts[-1])
        other = service.create_agent({'name': 'Other', 'role': 'Research'})['id']
        service.orchestration.prepare(service._agent(other))
        service.submit(other, {'text': 'Hello'})
        asyncio.run(service._agent(other).run())
        # Experience manifests are per agent, not a shared failure ledger.
        self.assertNotIn(job, service._agent(other).manifests['execution-experience'])

    def test_consolidation_receives_failure_evidence(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        self.factory.fail = True
        job = service.submit(agent.agid, {'text': 'Inspect'})['id']
        asyncio.run(agent.run())
        self.factory.fail = False
        service.orchestration.prepare(agent)
        learning = agent.submit('learning')
        asyncio.run(agent.run_selected([learning]))
        # Scripted output is not a memory patch, but every debate role receives evidence.
        for prompt in self.factory.prompts[-3:]:
            self.assertIn(job, prompt)
            self.assertIn('execution_failed', prompt)

    def test_failure_codes_reach_archive_and_job(self):
        service = self.service(start_worker=False)
        agent = service._agent(service.hierarchy.main)
        root = service.workspace.root(agent)
        class Factory:
            def spawn(self, spec):
                return LocalLLM(spec=spec, workdir=root, event_sink=lambda _: None)
        agent.factory = Factory()
        def fail(llm, prompt):
            llm._consume_event({'type': 'item.completed', 'item': {
                'id': '1', 'type': 'command_execution', 'command': 'python computer.py blindly apps',
                'aggregated_output': '{"code":"workflow_busy"}', 'exit_code': 75}})
            raise TimeoutError('deadline')
        job = service.submit(agent.agid, {'text': 'Inspect'})['id']
        with patch.object(CodexLLM, 'complete', fail):
            asyncio.run(agent.run())
        row = next(j for j in agent.state['jobs'] if j['id'] == job)
        self.assertEqual(row['failure_codes'], ['workflow_busy'])
        self.assertEqual(evidence(agent.state)[0]['codes'], ['timeout', 'workflow_busy'])

    def test_bounded_sanitized_and_learning_does_not_feed_itself(self):
        jobs = [dict(id=str(i), created=str(i), flow='chat', status='failed',
                     error='TimeoutError: SECRET', failure_codes=['workflow_busy', 'injected']) for i in range(15)]
        before = evidence({'jobs': jobs})
        self.assertEqual(len(before), 10)
        self.assertNotIn('SECRET', str(before))
        self.assertNotIn('injected', str(before))
        jobs.append(dict(id='learn', created='now', flow='learning', status='failed'))
        self.assertEqual(before, evidence({'jobs': jobs}))
        self.assertNotEqual(fingerprint({'manifests': {}}), fingerprint({'manifests': {'execution-experience': json.dumps(before)}}))
        self.assertIsNone(tool_failure({'type': 'command_execution', 'command': 'curl example.com',
            'aggregated_output': '{"code":"workflow_busy"}', 'exit_code': 75}))


class WorkflowTest(unittest.TestCase):
    def test_acquire_forward_read_release_and_timeout_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'execution-clock.json').write_text(json.dumps(dict(active=True, deadline='run1')))
            responses = [subprocess.CompletedProcess([], 0, '{"token":"test-token"}', ''),
                         subprocess.CompletedProcess([], 0, '{}', '')]
            with patch.object(workflow.subprocess, 'run', side_effect=responses) as run:
                workflow.invoke('blindly4', ['workflow', 'acquire'], root)
                workflow.invoke('blindly4', ['tree', '--pid', '123'], root)
                self.assertEqual(run.call_args.args[0][-2:], ['--lease', 'test-token'])
            llm = LocalLLM(spec=LLMSpec(role='conversation'), workdir=root, event_sink=lambda _: None)
            # Use the same clock generated by LocalLLM when simulating acquisition.
            def fail(instance, prompt):
                clock = json.loads((root/'execution-clock.json').read_text())
                (root/'workflow-lease.json').write_text(json.dumps(dict(deadline=clock['deadline'], token='owned')))
                raise TimeoutError('deadline')
            with patch.object(CodexLLM, 'complete', fail), patch.object(workflow.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], 0, '{}', '')) as run:
                with self.assertRaises(TimeoutError):
                    llm.complete('Inspect')
                self.assertIn('--lease', run.call_args.args[0])
                self.assertEqual(run.call_args.args[0][-1], 'owned')
            self.assertFalse((root/'workflow-lease.json').exists())

    def test_never_forward_or_release_other_execution_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'execution-clock.json').write_text(json.dumps(dict(active=True, deadline='new')))
            (root/'workflow-lease.json').write_text(json.dumps(dict(deadline='old', token='other')))
            with patch.object(workflow.subprocess, 'run', return_value=subprocess.CompletedProcess([],75,'{}','')) as run:
                workflow.invoke('blindly4', ['apps'], root)
                self.assertEqual(run.call_args.args[0], ['blindly4', 'apps'])
                workflow.release('blindly4', root)
                self.assertEqual(run.call_count, 1)

    def test_busy_acquisition_never_records_or_releases_unowned_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'execution-clock.json').write_text(json.dumps(dict(active=True, deadline='run')))
            with patch.object(workflow.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    [], 75, '{"code":"workflow_busy"}', '')) as run:
                result = workflow.invoke('blindly4', ['workflow', 'acquire'], root)
                self.assertEqual(result.returncode, 75)
                workflow.release('blindly4', root)
                self.assertEqual(run.call_count, 1)
            self.assertFalse((root/'workflow-lease.json').exists())

    def test_explicit_lease_preserved_and_cleanup_failure_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'execution-clock.json').write_text(json.dumps(dict(active=True, deadline='run')))
            (root/'workflow-lease.json').write_text(json.dumps(dict(deadline='run', token='owned')))
            with patch.object(workflow.subprocess, 'run', return_value=subprocess.CompletedProcess([],75,'{}','')) as run:
                workflow.invoke('blindly4', ['apps', '--lease', 'explicit'], root)
                self.assertEqual(run.call_args.args[0], ['blindly4', 'apps', '--lease', 'explicit'])
                self.assertIn('could not be released', workflow.release('blindly4', root))
                self.assertEqual(run.call_args.args[0][-1], 'owned')

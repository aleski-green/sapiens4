import os
from pathlib import Path
import unittest
import tempfile
import json
from unittest.mock import patch

from sapiens.runtime.codex import CodexLLM, CodexFactory
from sapiens.runtime.settings import execution_settings
from sapiens.corpora.host.service import Service
from sapiens.validation import APIError
from sapiens.runtime.contracts import LLMSpec, RUN_TIMEOUT_SECONDS


class ModelDefaultsTest(unittest.TestCase):
    def test_modes_share_one_limit_and_ignore_old_saved_timeouts(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = Path(directory)
            factory = CodexFactory(workdir=root)
            factory.execution = lambda: execution_settings(root)
            for mode, limit, effort in [('normal', 15, 'high'), ('deep', 1200, 'xhigh'), ('normal', 6000, 'high')]:
                policy = dict(mode=mode, timeout_seconds=limit)
                (root / 'execution.json').write_text(json.dumps(policy))
                llm = factory.spawn(LLMSpec())
                self.assertEqual(llm.timeout_seconds, RUN_TIMEOUT_SECONDS)
                self.assertEqual(llm.reasoning_effort, effort)
            policy.pop('mode')
            (root / 'execution.json').write_text(json.dumps(policy))
            self.assertEqual(execution_settings(root)['timeout_seconds'], 1800)
            (root / 'run-settings.json').write_text('{"mode":"deep","timeout_seconds":30}')
            self.assertEqual(factory.spawn(LLMSpec()).timeout_seconds, 1800)
            self.assertEqual(CodexFactory(workdir=root).spawn(LLMSpec()).timeout_seconds, 1800)

    def test_mode_api_persists_without_overwriting_legacy_budgets(self):
        with tempfile.TemporaryDirectory() as directory:
            service = Service(directory, start_worker=False)
            try:
                agent = service._agent(service.registry.main)
                legacy = agent.root / 'execution.json'
                legacy.write_text('{"max_tools":1}')
                data = dict(name='SapiTheMain', role='Assistant', execution=dict(mode='deep'))
                service.update_agent(agent.agid, data)
                self.assertEqual(service.snapshot()['orchestration'][agent.agid]['execution'], dict(mode='deep', timeout_seconds=1800))
                self.assertEqual(json.loads((agent.root / 'run-settings.json').read_text()), {'mode': 'deep'})
                self.assertEqual(agent.runner.factory.spawn(LLMSpec()).timeout_seconds, 1800)
                helper = service.create_agent(dict(name='Helper', role='Assistant'))
                self.assertEqual(service._agent(helper['id']).runner.factory.spawn(LLMSpec()).timeout_seconds, 1800)
                self.assertEqual(legacy.read_text(), '{"max_tools":1}')
                for invalid in (None, {}, dict(mode='automatic', timeout_seconds=300), dict(mode='normal', timeout_seconds=1200)):
                    with self.assertRaises(APIError):
                        service.update_agent(agent.agid, {**data, 'execution': invalid})
            finally:
                service.close()

    def command(self, model='default', resume=False):
        with patch('sapiens.runtime.codex.codex_binary', return_value='/bin/codex'):
            return CodexLLM(spec=LLMSpec(model=model), workdir=Path('/tmp'),
                            resume=resume, id='test-session')._command('hello')

    def test_defaults_apply_to_new_and_resumed_calls(self):
        with patch.dict(os.environ, {}, clear=True):
            for resume in (False, True):
                with self.subTest(resume=resume):
                    command = self.command(resume=resume)
                    self.assertIn('model="gpt-6-sol"', command)
                    self.assertIn('model_reasoning_effort="high"', command)
                    if resume:
                        self.assertIn('resume', command)

    def test_host_overrides_and_explicit_sdk_model_precedence(self):
        with patch.dict(os.environ, {'SAPIENS_CODEX_MODEL': 'gpt-6-astra',
                                     'SAPIENS_CODEX_REASONING_EFFORT': 'high'}):
            command = self.command()
            self.assertIn('model="gpt-6-astra"', command)
            self.assertIn('model_reasoning_effort="high"', command)
            command = self.command(model='gpt-5.6-luna', resume=True)
            self.assertEqual(command[command.index('--model') + 1], 'gpt-5.6-luna')
            self.assertFalse(any(arg.startswith('model=') for arg in command))


if __name__ == '__main__':
    unittest.main()

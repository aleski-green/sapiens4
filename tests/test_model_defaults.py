import os
from pathlib import Path
import unittest
from unittest.mock import patch

from sapiens.runtime import LocalLLM
from agentpy.interfaces import LLMSpec


class ModelDefaultsTest(unittest.TestCase):
    def command(self, model='default', resume=False):
        with patch('sapiens.runtime.codex_binary', return_value='/bin/codex'):
            return LocalLLM(spec=LLMSpec(model=model), workdir=Path('/tmp'),
                            resume=resume, id='test-session')._command('hello')

    def test_defaults_apply_to_new_and_resumed_calls(self):
        with patch.dict(os.environ, {}, clear=True):
            for resume in (False, True):
                with self.subTest(resume=resume):
                    command = self.command(resume=resume)
                    self.assertIn('model="gpt-5.6-sol"', command)
                    self.assertIn('model_reasoning_effort="xhigh"', command)
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

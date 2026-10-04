"""Harness defaults, provider separation, Kimi output and failure contracts."""
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from sapiens.runtime.harness import HarnessLLM, HarnessFactory
from sapiens.runtime.contracts import LLMSpec
from sapiens.runtime.settings import harness_name, model_defaults
from sapiens import preflight


class HarnessAdapterTest(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {}, clear=True)
        env.start()
        self.addCleanup(env.stop)

    def test_kimi_default_and_explicit_model(self):
        self.assertEqual(harness_name(), 'kimi')
        self.assertEqual(model_defaults(), ('kimi-for-coding', 'high'))
        with patch('sapiens.runtime.harness.harness_binary', return_value='/bin/kimi'):
            llm = HarnessFactory(Path('/tmp')).spawn(LLMSpec())
            command = llm._command('quoted "prompt"\n--option')
            self.assertEqual(command, ['/bin/kimi', '-p', 'quoted "prompt"\n--option', '--model', 'kimi-for-coding', '--output-format', 'stream-json'])
            self.assertEqual(HarnessFactory(execution=lambda: {'mode':'deep'}).spawn(LLMSpec()).reasoning_effort, 'max')
            custom = HarnessLLM(LLMSpec(model='my-k3'), Path('/tmp'))._command('hi')
            self.assertEqual(custom[custom.index('--model')+1], 'my-k3')

    def test_provider_override_and_invalid_provider(self):
        with patch.dict(os.environ, {'SAPIENS_HARNESS':'codex'}):
            self.assertEqual(model_defaults(), ('gpt-6-sol', 'high'))
        with patch.dict(os.environ, {'SAPIENS_HARNESS':'unknown'}):
            with self.assertRaises(ValueError): harness_name()
        with patch.dict(os.environ, {'SAPIENS_KIMI_MODEL':'k3-alias', 'SAPIENS_KIMI_REASONING_EFFORT':'max'}):
            self.assertEqual(model_defaults(), ('k3-alias', 'max'))

    def worker(self, code):
        llm = HarnessLLM(LLMSpec(), Path.cwd())
        llm._command = lambda _: [sys.executable, '-u', '-c', code]
        return llm

    def test_kimi_stream_final_message_and_effort_environment(self):
        events = [dict(role='meta', type='system.version', version='2.1.1'), dict(role='assistant', content='intermediate', tool_calls=[dict(id='1',function=dict(name='Shell'))]),
                  dict(role='tool',tool_call_id='1',content='tool result'),
                  dict(role='assistant',content=[dict(type='text',text='final')])]
        code = 'import os; assert os.environ["KIMI_MODEL_THINKING_EFFORT"]=="high"; ' + '; '.join('print('+repr(json.dumps(e))+')' for e in events)
        llm = self.worker(code)
        self.assertEqual(llm.complete('test'), 'final')
        self.assertEqual(llm.activity['last_action'], 'Shell')
        self.assertFalse(llm._tools)

    def test_failure_and_empty_output(self):
        with self.assertRaisesRegex(RuntimeError, 'exit 7'):
            self.worker('import sys; print("authentication failed", file=sys.stderr); sys.exit(7)').complete('test')
        with self.assertRaisesRegex(RuntimeError, 'without an agent message'):
            self.worker('print("unexpected non-JSON output")').complete('test')
        with self.assertRaisesRegex(RuntimeError, 'Unexpected Kimi'):
            self.worker('print(\'{"error":"rejected"}\')').complete('test')

    def test_missing_kimi_preflight_is_actionable(self):
        with patch('sapiens.preflight.harness_binary', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'Kimi CLI was not found'): preflight.check()

    def test_kimi_preflight_probes_actual_adapter(self):
        with patch('sapiens.preflight.harness_binary',return_value='/bin/kimi'), patch('sapiens.preflight.subprocess.run') as run, patch('sapiens.preflight.HarnessLLM.complete',return_value='SAPIENS_PREFLIGHT_OK') as complete:
            run.return_value.stdout='kimi, version 1.0'
            result=preflight.check()
            self.assertEqual(result['provider'],'kimi')
            self.assertEqual(result['model'],'kimi-for-coding')
            complete.assert_called_once()

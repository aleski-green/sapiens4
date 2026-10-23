"""The managed helper must emit UTF-8 even from a legacy Windows shell."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'sapiens/computer/commands.py'
LABEL = 'SimSpot \u25cf \u2302 caf\u00e9 \u0645\u0631\u062d\u0628\u0627'


class ComputerEncodingTests(unittest.TestCase):
    def helper(self, stdout='', stderr='', code=0, *, mode='blindly', error=None):
        # Only the real CLI entrypoint/streams are exercised. No desktop calls,
        # computer reservation, or persistent workspace changes take place.
        script = f'''
import runpy, subprocess, sys
from unittest.mock import patch
sys.argv = [{str(HELPER)!r}, {mode!r}, 'find']
with patch('subprocess.run', return_value=subprocess.CompletedProcess([], {code}, {stdout!r}, {stderr!r}), side_effect={('OSError(' + repr(error) + ')') if error else 'None'}):
    runpy.run_path({str(HELPER)!r}, run_name='__main__')
'''
        with tempfile.TemporaryDirectory() as folder:
            return subprocess.run(
                [sys.executable, '-c', script], cwd=folder,
                env={**os.environ, 'PYTHONUTF8': '0', 'PYTHONIOENCODING': 'cp1252:strict'},
                capture_output=True, text=True, encoding='utf-8', timeout=15)

    def test_unicode_find_output_is_utf8_without_launch_override(self):
        payload = {'matches': [{'path': '0.2', 'role': 'AXStaticText', 'title': LABEL}]}
        result = self.helper(json.dumps(payload))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['matches'][0]['title'], LABEL)

    def test_unicode_plain_outline_is_preserved(self):
        result = self.helper('0.2 AXStaticText ' + LABEL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), '0.2 AXStaticText ' + LABEL)

    def test_error_code_and_unicode_stderr_survive(self):
        payload = {'code': 'accessibility_error', 'error': 'Blocked ' + LABEL}
        result = self.helper(json.dumps(payload), 'Diagnostic ' + LABEL, 77)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), payload)
        self.assertEqual(result.stderr.strip(), 'Diagnostic ' + LABEL)

    def test_unicode_exception_remains_structured_json(self):
        result = self.helper(error='Missing ' + LABEL)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['error'], 'Missing ' + LABEL)
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()

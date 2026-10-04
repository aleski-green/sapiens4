"""Windows persistence, process lifetime and portable path regressions."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from sapiens.files import atomic_bytes, file_lock, read_bytes
from sapiens.paths import blindly_binary, shell_command
from sapiens.runtime.codex import CodexLLM
from sapiens.runtime.contracts import LLMSpec
from sapiens.corpora.host.service import Service


class PortableTests(unittest.TestCase):
    def test_direct_helper_runs_with_isolated_python(self):
        helper = Path(__file__).resolve().parents[1] / 'sapiens/computer/commands.py'
        result = subprocess.run([sys.executable, '-I', str(helper)], capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Usage:', json.loads(result.stdout)['error'])

    def test_large_unicode_prompt_uses_stdin(self):
        code = ('import json,sys; value=sys.stdin.read(); '
                'print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":value}}))')
        with tempfile.TemporaryDirectory() as folder:
            llm = CodexLLM(LLMSpec(), Path(folder), timeout_seconds=10)
            llm._command = lambda prompt: [sys.executable, '-X', 'utf8', '-c', code]
            message = 'Windows مرحبا café 🪟\n' * 5000
            self.assertEqual(llm.complete(message), message)

    def test_concurrent_atomic_reads_never_see_partial_json(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'state.json'
            atomic_bytes(path, b'{"n":0}')
            failures = []
            def reader():
                try:
                    for _ in range(300):
                        self.assertIsInstance(json.loads(read_bytes(path))['n'], int)
                except BaseException as error:
                    failures.append(error)
            worker = threading.Thread(target=reader)
            worker.start()
            for n in range(100):
                atomic_bytes(path, json.dumps({'n': n}).encode())
            worker.join()
            self.assertEqual(failures, [])

    def test_file_lock_excludes_another_process_and_releases(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'host.lock'
            code = ('from pathlib import Path; from sapiens.files import file_lock; '
                    f'lock=file_lock(Path({str(path)!r}),blocking=False); lock.__enter__(); lock.__exit__(None,None,None)')
            with file_lock(path):
                result = subprocess.run([sys.executable, '-c', code], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'BlockingIOError', result.stderr)
            self.assertEqual(subprocess.run([sys.executable, '-c', code], capture_output=True).returncode, 0)


@unittest.skipUnless(sys.platform == 'win32', 'Windows integration')
class WindowsTests(unittest.TestCase):
    def test_powershell_command_preserves_spaces_apostrophe_and_unicode(self):
        message = "مرحبا O'Brien $literal & stuff"
        command = shell_command((sys.executable, '-X', 'utf8', '-c', 'import sys; print(sys.argv[1])', message))
        result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', '[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); ' + command], capture_output=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), message)

    def test_windows_binary_and_override(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertTrue(str(blindly_binary()).endswith('windows\\blindly4.exe'))
        with patch.dict(os.environ, {'SAPIENS_BLINDLY_BINARY': str(Path.cwd() / 'custom.exe')}):
            self.assertEqual(blindly_binary(), Path.cwd() / 'custom.exe')

    def test_file_uri_round_trip_with_spaces_unicode_and_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            service = Service(folder, start_worker=False)
            try:
                agent = service._agent(service.registry.main)
                document = service.workspace.root(agent) / 'مرحبا #1.html'
                document.write_text('Hello', encoding='utf-8')
                by_path = service.workspace.destination(agent, {'path': str(document)})
                by_uri = service.workspace.destination(agent, {'url': document.as_uri()})
                self.assertEqual(by_path, by_uri)
            finally:
                service.close()

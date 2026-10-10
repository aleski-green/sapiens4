"""Subprocess lifecycle tests without calling an LLM service."""
import sys
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from sapiens.runtime.contracts import LLMSpec
from sapiens.runtime.codex import CodexLLM


class ProcessTests(unittest.TestCase):
    def worker(self, code, **kwargs):
        llm = CodexLLM(LLMSpec(), Path.cwd(), **kwargs)
        llm._command = lambda prompt: [sys.executable, "-u", "-c", code]
        return llm

    def test_timeout(self):
        llm = self.worker("import time; time.sleep(30)", timeout_seconds=0.1)
        with self.assertRaises(TimeoutError):
            llm.complete("test")

    def test_success(self):
        llm = self.worker('print(\'{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}\')')
        self.assertEqual(llm.complete("test"), "OK")

    def test_interrupt(self):
        llm = self.worker('import time; print(\'{"type":"turn.started"}\'); time.sleep(30)')
        def interrupt(text):
            raise KeyboardInterrupt
        llm._consume_event = interrupt
        with self.assertRaises(KeyboardInterrupt):
            llm.complete("test")

    def test_failed_turn(self):
        llm = self.worker('print(\'{"type":"turn.failed","error":{"message":"test failure"}}\')')
        with self.assertRaisesRegex(RuntimeError, "test failure"):
            llm.complete("test")

    def test_stop_and_timeout_kill_detached_child_commands(self):
        for cancel in (True, False):
            with self.subTest(cancel=cancel), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'child'
                code = ('import subprocess,sys,time; from pathlib import Path; '
                        'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],start_new_session=True); '
                        f'Path({str(path)!r}).write_text(str(p.pid)); '
                        'print(\'{"type":"turn.started"}\',flush=True); time.sleep(30)')
                llm = self.worker(code, timeout_seconds=.3)
                if cancel:
                    llm._consume_event = lambda _: llm.cancel_event.set()
                with self.assertRaises(InterruptedError if cancel else TimeoutError):
                    llm.complete('test')
                pid = int(path.read_text())
                if os.name == 'nt':
                    rows = subprocess.run(['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV', '/NH'], capture_output=True, text=True).stdout
                    state = 'running' if f'"{pid}"' in rows else ''
                else:
                    state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                if state and not state.startswith('Z'):
                    os.kill(pid, 9)  # Clean up only the child created by this test.
                    self.fail('A detached command survived the stopped runner')

    def test_cancel_before_launch_and_parallel_activity(self):
        llm = self.worker('raise RuntimeError("must not launch")')
        llm.cancel_event.set()
        with self.assertRaises(InterruptedError):
            llm.complete('test')
        for identity in ('a', 'b'):
            llm._consume_event(dict(type='item.started', item=dict(id=identity, type='command_execution', command=identity)))
        llm._consume_event(dict(type='item.completed', item=dict(id='a', type='command_execution', command='a')))
        self.assertEqual(llm.activity['tool'], 'b')
        self.assertEqual(llm.activity['phase'], 'Running tool')
        llm._consume_event(dict(type='item.completed', item=dict(id='b', type='command_execution', command='b')))
        self.assertEqual(llm.activity['phase'], 'Waiting for model')
        self.assertEqual(llm.activity['last_action'], 'b')

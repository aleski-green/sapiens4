"""Subprocess lifecycle tests without calling an LLM service."""
import sys
import unittest
from pathlib import Path

from agentpy import LLMSpec
from agentpy.codex import CodexLLM


class ProcessTests(unittest.TestCase):
    def worker(self, code, **kwargs):
        llm = CodexLLM(LLMSpec(), Path.cwd(), event_sink=lambda text: None, **kwargs)
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
        llm.event_sink = interrupt
        with self.assertRaises(KeyboardInterrupt):
            llm.complete("test")

    def test_failed_turn(self):
        llm = self.worker('print(\'{"type":"turn.failed","error":{"message":"test failure"}}\')')
        with self.assertRaisesRegex(RuntimeError, "test failure"):
            llm.complete("test")

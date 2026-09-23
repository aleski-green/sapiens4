import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch
from concurrent.futures import ThreadPoolExecutor

from sapiens.discovery import admission, blocker
from sapiens.execution import start
from sapiens.runtime import LocalFactory, LocalLLM, CodexLLM
from sapiens.sdk import LLMSpec
from sapiens.usage import DEFAULTS


class DiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.clock = start(300,100)
        (self.root/'execution-clock.json').write_text(json.dumps(self.clock))

    def admit(self, command='find'):
        with admission(self.root,command) as reason:
            return reason

    def test_parallel_discovery_is_bounded_and_new_run_resets(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.admit(),range(20)))
        self.assertEqual(results.count(None),12)
        self.assertIn('12 live UI',blocker(self.root,self.clock['deadline']))
        self.assertIsNone(self.admit('workflow'))
        self.clock = start(300,100)
        (self.root/'execution-clock.json').write_text(json.dumps(self.clock))
        self.assertIsNone(self.admit())

    def test_cutoff_blocks_live_reads_before_hard_deadline(self):
        self.clock['discovery_until'] = (datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()
        (self.root/'execution-clock.json').write_text(json.dumps(self.clock))
        self.assertIn('time allowance',self.admit('tree'))
        self.assertGreater(datetime.fromisoformat(self.clock['deadline']),datetime.now(timezone.utc))

    def test_recovery_does_not_claim_a_saved_draft(self):
        llm=LocalLLM(spec=LLMSpec(role='conversation'),workdir=self.root,event_sink=lambda _:None)
        def fail(instance,prompt):
            self.assertIn('Live UI discovery stops',prompt)
            for _ in range(13): self.admit()
            raise TimeoutError('test deadline')
        with patch.object(CodexLLM,'complete',fail):
            result=llm.complete('Research')
        self.assertIn('No draft was saved',result)
        self.assertIn('Incomplete',llm.warning)

    def test_per_agent_timeout_and_explicit_cap(self):
        for cap, expected in [(None,600),(300,300)]:
            factory=LocalFactory(workdir=self.root,event_sink=lambda _:None,timeout_seconds=cap)
            factory.execution={**DEFAULTS,'timeout_seconds':600}
            self.assertEqual(factory.spawn(LLMSpec(role='conversation')).timeout_seconds,expected)

    def test_wrapper_refuses_live_read_without_calling_binary(self):
        import os
        from contextlib import redirect_stdout
        from io import StringIO
        from sapiens.computer import main
        for _ in range(12): self.admit()
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            output = StringIO()
            with patch('sapiens.computer.workflow_invoke') as invoke, redirect_stdout(output):
                code = main(['blindly','find','--pid','1','--title','Experience'])
            invoke.assert_not_called()
            self.assertEqual(code,75)
            self.assertEqual(json.loads(output.getvalue())['code'],'discovery_stopped')
        finally:
            os.chdir(previous)

import asyncio
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.runtime import LocalLLM
from agentpy.interfaces import LLMSpec
from sapiens.computer import bounded_output
from sapiens.computer_read import read
from sapiens.foreground import ForegroundReturn


class ReadWrapperTest(unittest.TestCase):
    def test_accessibility_error_codes_survive_wrapper(self):
        for code in ('focus_unavailable', 'accessibility_permission_denied', 'accessibility_error'):
            payload = dict(code=code, error='Accessibility diagnostic')
            self.assertEqual(json.loads(bounded_output(json.dumps(payload), 800)), payload)

    def test_compacts_find_before_truncation(self):
        matches = [dict(path=str(i),role='AXStaticText',value=f'Message {i}',attributes=['noise']*100) for i in range(10)]
        result = json.loads(bounded_output(json.dumps(dict(matches=matches)), 1200))
        self.assertEqual(len(result['matches']),10)
        self.assertNotIn('attributes',result['matches'][0])

    def test_subtree_pagination_uses_one_scan_and_original_paths(self):
        tree = dict(role='AXApplication',children=[dict(role='AXGroup',children=[
            dict(role='AXStaticText',value=f'Message {i} '+'x'*60) for i in range(30)]),
            dict(role='AXStaticText',value='Other channel')])
        calls=[]
        def invoke(args):
            calls.append(args)
            return subprocess.CompletedProcess(args,0,json.dumps(dict(tree=tree,truncated=True)),'')
        with tempfile.TemporaryDirectory() as root:
            first=read(['--pid','1','--path','0'],invoke,root,1000)
            rows=first['nodes'][:]; current=first
            while current['next_offset'] is not None:
                current=read(['--snapshot',first['snapshot'],'--offset',str(current['next_offset'])],invoke,root,1000)
                rows.extend(current['nodes'])
            self.assertEqual(len(calls),1)
            self.assertEqual(len(rows),31)
            self.assertEqual(rows[-1]['path'],'0.29')
            self.assertTrue(first['truncated'])
            self.assertNotIn('Other channel',str(rows))
            with self.assertRaises(ValueError):read(['--snapshot','../bad'],invoke,root,1000)

    def test_missing_target_is_not_empty_success(self):
        with tempfile.TemporaryDirectory() as root:
            invoke=lambda args:subprocess.CompletedProcess(args,0,json.dumps({'tree':{},'truncated':True}),'')
            with self.assertRaisesRegex(ValueError,'Coverage is incomplete'):
                read(['--pid','1','--path','0.4'],invoke,root,1000)


class RecoveryTest(IntegrationFixture):
    def test_foreground_restoration_runs_on_success_error_and_limit(self):
        root=Path(self.directory.name)
        for outcome in ('ok',RuntimeError('provider error')):
            llm=LocalLLM(spec=LLMSpec(role='conversation'),workdir=root,event_sink=lambda _:None)
            with patch('sapiens.runtime.ForegroundReturn') as foreground, patch('sapiens.runtime.CodexLLM.complete',side_effect=outcome if isinstance(outcome,Exception) else None,return_value='ok'):
                foreground.return_value.restore.return_value=None
                if isinstance(outcome,Exception):
                    with self.assertRaises(RuntimeError):llm.complete('Read')
                else:llm.complete('Read')
                foreground.return_value.restore.assert_called_once()


class ForegroundTest(unittest.TestCase):
    def test_desktop_and_background_completion_never_open_workspace_url(self):
        for bundle in ('com.sapiens4.desktop', 'com.apple.finder', None):
            with self.subTest(bundle=bundle), tempfile.TemporaryDirectory() as root:
                root=Path(root)
                (root/'host-control.json').write_text('{}')
                with patch('sapiens.foreground.sys.platform','darwin'), patch('sapiens.foreground.front_bundle',return_value=bundle), patch('sapiens.foreground.subprocess.run') as run:
                    run.return_value.returncode=0
                    guard=ForegroundReturn(root)
                    (root/'.computer-used').touch()
                    self.assertIsNone(guard.restore())
                    if bundle == 'com.sapiens4.desktop':
                        run.assert_called_once_with(['/usr/bin/open','-b',bundle],capture_output=True,text=True,timeout=5)
                    else:
                        run.assert_not_called()

    def test_only_restore_when_computer_was_used(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            (root/'host-control.json').write_text(json.dumps({'url':'http://127.0.0.1:4175/api/agents/a/control'}))
            with patch('sapiens.foreground.sys.platform','darwin'), patch('sapiens.foreground.front_bundle',return_value='com.openai.codex'), patch('sapiens.foreground.subprocess.run') as run:
                run.return_value.returncode=0
                guard=ForegroundReturn(root)
                guard.restore()
                run.assert_not_called()
                (root/'.computer-used').touch()
                self.assertIsNone(guard.restore())
                self.assertEqual(run.call_args.args[0],['/usr/bin/open','-b','com.openai.codex'])

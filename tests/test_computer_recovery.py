import asyncio
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_integration import IntegrationFixture
from sapiens.runtime.codex import CodexLLM
from sapiens.corpora.host.service import complete_with_computer
from sapiens.runtime.contracts import LLMSpec
from sapiens.computer.commands import bounded_output
from sapiens.computer.reader import read
from sapiens.computer.focus import ForegroundReturn
from sapiens.validation import APIError


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
    def test_host_restores_focus_before_releasing_computer_and_reports_warning(self):
        service = self.service(start_worker=False)
        first = service.registry.main
        second = service.create_agent(dict(name='Second', role='Assistant'))['id']
        for agid in (first, second):
            service.submit(agid, dict(text='Work'))
            with service._agent(agid).transaction() as state:
                state['turns'][-1]['status'] = 'running'
        service.acquire_computer(first)
        llm = CodexLLM(spec=LLMSpec(), workdir=Path(self.directory.name))
        def restore():
            self.assertEqual(service._active, first)
            with self.assertRaisesRegex(APIError, 'busy'):
                service.acquire_computer(second)
            return 'Focus could not be restored'
        with patch('sapiens.corpora.host.service.ForegroundReturn') as foreground, \
             patch.object(llm, 'complete', return_value='reply'):
            foreground.return_value.restore.side_effect = restore
            result = complete_with_computer(llm, 'Work', lambda restore: service.release_computer(first, restore))
        self.assertEqual(result, 'reply')
        self.assertIsNone(service._active)
        self.assertEqual(llm.warning, 'Focus could not be restored')

    def test_foreground_restoration_runs_on_success_error_and_limit(self):
        root=Path(self.directory.name)
        for outcome in ('ok',RuntimeError('provider error'),TimeoutError('timeout'),InterruptedError('stopped')):
            llm=CodexLLM(spec=LLMSpec(role='conversation'),workdir=root)
            with patch('sapiens.corpora.host.service.ForegroundReturn') as foreground, patch('sapiens.runtime.codex.CodexLLM.complete',side_effect=outcome if isinstance(outcome,Exception) else None,return_value='ok'):
                foreground.return_value.restore.return_value=None
                if isinstance(outcome,Exception):
                    with self.assertRaises(type(outcome)):complete_with_computer(llm, 'Read')
                else:complete_with_computer(llm, 'Read')
                foreground.return_value.restore.assert_called_once()


class ForegroundTest(unittest.TestCase):
    def test_desktop_and_background_completion_never_open_workspace_url(self):
        for bundle in ('com.sapiens4.desktop', 'com.apple.finder', None):
            with self.subTest(bundle=bundle), tempfile.TemporaryDirectory() as root:
                root=Path(root)
                (root/'host-control.json').write_text('{}')
                with patch('sapiens.computer.focus.sys.platform','darwin'), patch('sapiens.computer.focus.front_bundle',return_value=bundle), patch('sapiens.computer.focus.subprocess.run') as run:
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
            with patch('sapiens.computer.focus.sys.platform','darwin'), patch('sapiens.computer.focus.front_bundle',return_value='com.openai.codex'), patch('sapiens.computer.focus.subprocess.run') as run:
                run.return_value.returncode=0
                guard=ForegroundReturn(root)
                guard.restore()
                run.assert_not_called()
                (root/'.computer-used').touch()
                self.assertIsNone(guard.restore())
                self.assertEqual(run.call_args.args[0],['/usr/bin/open','-b','com.openai.codex'])

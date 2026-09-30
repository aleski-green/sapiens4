"""A source-only release must boot without either lab checkout or Git metadata."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock

from sapiens.corpora.host.service import Service
from sapiens.corpora.sapis.conversations import Conversation
from sapiens.runtime.contracts import Flow, Role
from sapiens.runtime.turns import TurnRunner
from sapiens.validation import APIError


ROOT = Path(__file__).resolve().parents[1]


class RuntimeDistributionTest(unittest.TestCase):
    def test_source_only_release_in_an_isolated_process(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / 'release'
            for name in ('sapiens', 'web', 'prompts'):
                shutil.copytree(ROOT / name, release / name,
                                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            result = subprocess.run([sys.executable, '-I', '-c', '''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
before = list(sys.path)
from sapiens.runtime.turns import TurnRunner
assert not any(m.startswith(('sapiens.corpora', 'sapiens.computer')) for m in sys.modules)
from sapiens.corpora.host.assets import asset
from sapiens.corpora.host.service import Service
from sapiens.corpora.sapis.conversations import Config, Conversation
assert sys.path == before, 'Importing the runtime must not alter module search paths'
assert 'config' not in sys.modules, 'Behavior config must have a qualified module name'
# Installed updaters use these paths before the new updater can be installed.
from sapiens.assets import index, javascript
from sapiens.service import Service as InstalledService
from sapiens.server import Server, Handler
index(), javascript()
assert InstalledService is Service
for url in ('/', '/workspace/', '/workspace/app.js', '/workspace/styles.css',
            '/assets/sapi-theme.css', '/assets/sapi-theme.js',
            '/live.css'):
    mime, body = asset(url)
    assert body and mime, url
for url in ('/agentpy/config.py', '/web/bootstrap.js', '/.git/config',
            '/.sapiens4/corpora.sqlite3', '/workspace/fixtures/sapiens-cases.js'):
    assert asset(url) is None, url
service = Service(Path(sys.argv[2]), start_worker=False)
try:
    agent = service._agent(service.registry.main)
    assert (service.workspace.root(agent) / 'Notes.html').is_file()
    assert service.snapshot()['main_agent_id'] == agent.agid
    conversation = Conversation(agid=agent.agid, root=service.root)
    context = conversation.context({'chat': []}, 'hello', Config)
    example = Path(context['notes_example'])
    assert example == Path(sys.argv[1]).resolve() / 'prompts/examples/jarvis-notes.html'
    assert '(◉﹏◉)' in example.read_text()
    assert str(example) in Config.roles['conversation'].prompt.format_map(context)
finally:
    service.close()
''', str(release), str(Path(directory) / 'state')],
                cwd=directory, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_runner_accepts_supplied_context_without_initializing_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'uncreated'
            store = SimpleNamespace(root=root)
            context = Mock(return_value={'task': 'prepared input'})
            llm = SimpleNamespace(id='fake', complete=Mock(return_value='reply'))
            config = SimpleNamespace(flows={'chat': Flow(('conversation',))},
                                     roles={'conversation': Role('{task}')})
            runner = TurnRunner(store=store, context=context, config=config,
                                factory=SimpleNamespace(spawn=lambda spec: llm))
            outcome = runner._work({'input': 'request', 'flow': 'chat'}, {}, config)
            self.assertEqual(outcome.output, 'reply')
            context.assert_called_once_with({}, 'request', config)
            llm.complete.assert_called_once_with('prepared input')
            self.assertFalse(root.exists())
            self.assertIsNone(runner.active_llm)

    def test_conversation_reopen_keeps_existing_archive_and_manifest_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / 'agentpy'
            conversation = Conversation(agid='sapi_test', root=root)
            conversation.set_manifest('identity', 'Saved identity')
            conversation.archive('runs/test-turn', dict(output='Saved reply', logs=[{'answer': 'Saved reply'}]))
            with conversation.transaction() as state:
                state['chat'] = [dict(role='user', content=str(i)) for i in range(105)]
                conversation.trim(state)
            saved = conversation.path.read_bytes()
            reopened = Conversation(agid='sapi_test', root=root)
            self.assertEqual(reopened.path, root / 'agents/sapi_test/state.json')
            self.assertEqual(reopened.path.read_bytes(), saved)
            self.assertEqual(reopened.result('test-turn'), 'Saved reply')
            self.assertEqual(reopened.transcript('test-turn'), [{'answer': 'Saved reply'}])
            self.assertEqual(reopened.manifests, {'identity': 'Saved identity'})
            archives = list((root / 'corpora/archive/sapi_test/chat').glob('*.json'))
            self.assertEqual(len(json.loads(archives[0].read_text())), 5)
            self.assertEqual(len(reopened.state['chat']), 100)
            self.assertFalse((root / 'corpora/directory.json').exists(), 'Persistence must not register Sapis')

    def test_registration_is_explicit_and_reparenting_rejects_cycles_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            service = Service(directory, start_worker=False)
            self.addCleanup(service.close)
            registry = service.registry
            registry.register = Mock(wraps=registry.register)
            child = service.create_agent(dict(name='Child', role='Assistant'))['id']
            registry.register.assert_called_once_with(child, parent=registry.main)
            service._agent(child)
            registry.register.assert_called_once()
            grandchild = service.create_agent(dict(name='Grandchild', role='Assistant', manager=child))['id']
            before = (registry.root / 'directory.json').read_bytes()
            for parent in (child, grandchild, 'missing'):
                with self.assertRaises(APIError):
                    registry.register(child, parent=parent)
                self.assertEqual((registry.root / 'directory.json').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()

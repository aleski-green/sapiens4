"""A source-only release must boot without either lab checkout or Git metadata."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RuntimeDistributionTest(unittest.TestCase):
    def test_source_only_release_in_an_isolated_process(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / 'release'
            for name in ('agentpy', 'sapiens', 'web', 'prompts'):
                shutil.copytree(ROOT / name, release / name,
                                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            result = subprocess.run([sys.executable, '-I', '-c', '''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
before = list(sys.path)
from sapiens import sdk
from sapiens.assets import asset
from sapiens.service import Service
assert sys.path == before, 'Importing the runtime must not alter module search paths'
assert 'config' not in sys.modules, 'Behavior config must have a qualified module name'
for url in ('/', '/workspace/', '/workspace/app.js', '/workspace/styles.css',
            '/assets/sapi-theme.css', '/assets/sapi-theme.js',
            '/assets/group-avatar.js', '/live.css'):
    mime, body = asset(url)
    assert body and mime, url
for url in ('/agentpy/config.py', '/web/bootstrap.js', '/.git/config',
            '/.sapiens4/corpora.sqlite3', '/workspace/fixtures/sapiens-cases.js'):
    assert asset(url) is None, url
service = Service(Path(sys.argv[2]), start_worker=False)
try:
    agent = service._agent(service.hierarchy.main)
    assert (service.workspace.root(agent) / 'Notes.md').is_file()
    assert service.snapshot()['main_agent_id'] == agent.agid
finally:
    service.close()
''', str(release), str(Path(directory) / 'state')],
                cwd=directory, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()

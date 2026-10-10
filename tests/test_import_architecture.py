"""Recursive ownership, rTernarity and import boundaries for the owned source."""
import ast
from importlib.util import resolve_name
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'sapiens'


def modules():
    return {'.'.join(path.relative_to(ROOT).with_suffix('').parts).removesuffix('.__init__'): path
            for path in PACKAGE.rglob('*.py')}


class ImportArchitectureTest(unittest.TestCase):
    def test_recursive_import_graph_and_ownership(self):
        paths = modules()
        graph = {name: set() for name in paths}
        for name, path in paths.items():
            tree = ast.parse(path.read_text())
            package = name if path.name == '__init__.py' else name.rpartition('.')[0]
            parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
            for node in ast.walk(tree):
                if isinstance(node, ast.Call):
                    function = node.func
                    self.assertFalse(isinstance(function, ast.Name) and function.id == '__import__', name)
                    self.assertFalse(isinstance(function, ast.Attribute) and function.attr == 'import_module', name)
                if not isinstance(node, (ast.Import, ast.ImportFrom)):
                    continue
                parent = parents.get(node)
                while parent:
                    self.assertNotIsInstance(parent, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef),
                                             f'{name}:{node.lineno}: import belongs at module scope')
                    parent = parents.get(parent)
                if isinstance(node, ast.ImportFrom):
                    module = resolve_name('.' * node.level + (node.module or ''), package) if node.level else node.module
                    targets = [module, *(module + '.' + a.name for a in node.names)]
                else:
                    targets = [a.name for a in node.names]
                for target in targets:
                    self.assertFalse(target == 'agentpy' or target.startswith('agentpy.'), name)
                    self.assertNotEqual(target, 'sapiens.sdk', name)
                    # Direct-script imports must count toward the same graph.
                    if package + '.' + target in paths:
                        target = package + '.' + target
                    if target not in paths:
                        continue
                    graph[name].add(target)
                    self.assertNotIn(target, {'sapiens.assets', 'sapiens.service', 'sapiens.server'},
                                     'Only installed updater clients use the compatibility entrypoints')
                    if name.startswith('sapiens.runtime.'):
                        self.assertTrue(target.startswith('sapiens.runtime.') or target in
                                        {'sapiens.clock', 'sapiens.files'}, f'{name} must not depend on {target}')
                    if name.startswith('sapiens.corpora.sapis.'):
                        self.assertFalse(target.startswith(('sapiens.computer.', 'sapiens.corpora.host.')),
                                         f'Sapi persistence must not import {target}')
                        if target.startswith('sapiens.runtime.'):
                            self.assertEqual(target, 'sapiens.runtime.contracts')
                    if name.startswith('sapiens.computer.'):
                        self.assertFalse(target.startswith(('sapiens.corpora.', 'sapiens.runtime.')), name)
        visited = set()
        def visit(name, ancestors):
            self.assertNotIn(name, ancestors, 'Circular dependency: ' + ' -> '.join([*ancestors, name]))
            if name not in visited:
                for dependency in sorted(graph[name]):
                    visit(dependency, [*ancestors, name])
                visited.add(name)
        for name in graph:
            visit(name, [])

    def test_ternary_responsibilities_and_explicit_leaf_collections(self):
        shared = {'__init__.py', '__main__.py', 'clock.py', 'files.py', 'paths.py', 'preflight.py',
                  'prompts.py', 'validation.py', 'assets.py', 'service.py', 'server.py'}
        splits = {
            '': ({'sapiens', 'web', 'macos'}, {'blindly4', 'documentation', 'prompts', 'tests',
                                             'CONTRIBUTING.md', 'README.md', 'license', 'requirements-cli.txt', 'start.sh', 'sapiens4', 'windows', 'start.ps1', 'sapiens4.cmd'}),
            'sapiens': ({'corpora', 'runtime', 'computer'}, shared),
            'sapiens/corpora': ({'sapis', 'browser.py', 'host'}, {'__init__.py'}),
            'sapiens/computer': ({'commands.py', 'reader.py', 'focus.py'}, {'__init__.py'}),
            'web': ({'shell', 'features', 'theme'}, set()),
        }
        for path, (parts, support) in splits.items():
            actual = {p.name for p in (ROOT / path).iterdir()
                      if p.name != '__pycache__' and not p.name.startswith('.')}
            self.assertEqual(len(parts), 3)
            self.assertEqual(actual - support, parts, path)
            self.assertFalse(parts & support, path)
        # These collections implement one responsibility each; their file count follows behavior.
        collections = ('sapiens/corpora/sapis', 'sapiens/corpora/host', 'sapiens/runtime',
                       'web/shell', 'web/features', 'web/theme', 'macos')
        for path in collections:
            self.assertFalse(any(p.is_dir() and p.name != '__pycache__' for p in (ROOT / path).iterdir()), path)
        self.assertEqual({p.name for p in (ROOT / 'web').iterdir() if p.is_dir()}, {'shell', 'features', 'theme'})
        self.assertFalse(any((ROOT / 'agentpy').glob('*.py')))
        self.assertFalse((PACKAGE / 'sdk.py').exists())

    def test_every_nested_module_imports_in_a_fresh_process(self):
        with tempfile.TemporaryDirectory() as directory:
            for module in sorted(modules()):
                with self.subTest(module=module):
                    result = subprocess.run([sys.executable, '-I', '-c',
                        'import sys, importlib; sys.path.insert(0, sys.argv[1]); importlib.import_module(sys.argv[2])',
                        str(ROOT), module], cwd=directory, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()

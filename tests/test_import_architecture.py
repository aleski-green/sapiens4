"""Keep the host import graph acyclic, including conditional import branches."""
import ast
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'sapiens'


class ImportArchitectureTest(unittest.TestCase):
    def test_imports_are_at_module_scope_and_dependencies_are_acyclic(self):
        modules = {path.stem: ast.parse(path.read_text()) for path in PACKAGE.glob('*.py')}
        graph = {name: set() for name in modules}
        for name, tree in modules.items():
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
                    if node.level:
                        targets = [node.module.split('.')[0]] if node.module else [a.name for a in node.names]
                    elif node.module and node.module.startswith('sapiens.'):
                        targets = [node.module.split('.')[1]]
                    elif node.module == 'sapiens':
                        targets = [a.name for a in node.names]
                    else:
                        # Include direct-script fallback imports too.
                        targets = [node.module] if node.module in modules else []
                        if (node.module or '').startswith(('agentpy', 'config')):
                            self.assertEqual(name, 'sdk', 'SDK imports belong in the sdk adapter')
                else:
                    targets = [a.name.split('.')[1] if a.name.startswith('sapiens.') else a.name for a in node.names]
                graph[name].update(target for target in targets if target in modules)

        visited = set()
        def visit(name, path):
            self.assertNotIn(name, path, 'Circular dependency: ' + ' -> '.join([*path, name]))
            if name in visited:
                return
            for dependency in sorted(graph[name]):
                visit(dependency, [*path, name])
            visited.add(name)
        for name in sorted(graph):
            visit(name, [])

    def test_every_module_imports_in_a_fresh_process(self):
        # Catch hidden requirements such as importing runtime before SDK helpers.
        with tempfile.TemporaryDirectory() as directory:
            for path in sorted(PACKAGE.glob('*.py')):
                with self.subTest(module=path.stem):
                    result = subprocess.run([sys.executable, '-I', '-c',
                        'import sys, importlib; sys.path.insert(0, sys.argv[1]); importlib.import_module(sys.argv[2])',
                        str(ROOT), 'sapiens.' + path.stem], cwd=directory, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()

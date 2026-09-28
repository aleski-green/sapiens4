"""Versioned adaptive files. Policy and activation belong to the host runtime."""
from __future__ import annotations

import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

from .storage import atomic_bytes, atomic_json, encode, safe_child


class Morphos:
    def __init__(self, root, source, policy):
        self.root = Path(root)
        self.source = Path(source).resolve()
        self.policy = policy

    def _allowed(self, name):
        safe_child(self.root, name)
        return any(fnmatch.fnmatchcase(name, pattern) for pattern in self.policy.editable)

    def files(self, version=None):
        if version:
            root = safe_child(self.root / "versions", version)
            return json.loads((root / "files.json").read_bytes())
        files = {}
        for pattern in self.policy.editable:
            for path in self.source.glob(pattern):
                if path.is_file() and not path.is_symlink():
                    files[path.relative_to(self.source).as_posix()] = path.read_text()
        return files

    def stage(self, changes, *, base=None):
        if not isinstance(changes, dict) or not changes:
            raise ValueError("Morphosis must supply a nonempty files object")
        files = self.files(base)
        for name, content in changes.items():
            if not self._allowed(name) or not isinstance(content, str):
                raise ValueError(f"Morphosis cannot change {name!r}")
            if len(content.encode()) > self.policy.max_file_bytes:
                raise ValueError("Morphosis file size limit exceeded")
            files[name] = content
        if "config.py" not in files:
            raise ValueError("Morphos requires config.py")
        for name, content in files.items():
            if name.endswith(".py"):
                compile(content, name, "exec")
        version = hashlib.sha256(encode(files)).hexdigest()[:20]
        directory = self.root / "versions" / version
        for name, content in files.items():
            atomic_bytes(safe_child(directory, name), content.encode())
        atomic_json(directory / "files.json", files)
        # Run import/contract validation in a separate local process. This is not a sandbox.
        check = (
            "import importlib.util, sys; sys.path.insert(0, sys.argv[1]); "
            "s = importlib.util.spec_from_file_location('_candidate', 'config.py', submodule_search_locations=['.']); "
            "m = importlib.util.module_from_spec(s); sys.modules['_candidate'] = m; s.loader.exec_module(m); "
            "from agentpy.validation import validate_config; validate_config(m.Config())"
        )
        env = dict(os.environ)
        sdk = str(Path(__file__).resolve().parent.parent)
        for command in ((sys.executable, "-c", check, sdk), *self.policy.checks):
            completed = subprocess.run(command, cwd=directory, env=env, capture_output=True,
                                       text=True, timeout=self.policy.timeout_seconds)
            if completed.returncode:
                raise ValueError(f"Morphosis check failed: {completed.stderr[-2000:]}")
        atomic_json(directory / "validated.json", {"version": version})
        return version

    def load(self, version):
        directory = safe_child(self.root / "versions", version)
        if not (directory / "validated.json").exists():
            raise ValueError("Morphos version has not passed validation")
        # A package permits relative imports (e.g. from .behaviors import awake).
        name = f"_agentpy_body_{version}"
        spec = importlib.util.spec_from_file_location(name, directory / "config.py",
                                                     submodule_search_locations=[str(directory)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
            return module.Config()
        except BaseException:
            sys.modules.pop(name, None)
            raise

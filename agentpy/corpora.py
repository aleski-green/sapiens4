"""Shared archives and agent directory."""
from __future__ import annotations

import json
from pathlib import Path

from .storage import atomic_json, file_lock, safe_child


class Corpora:
    def __init__(self, root):
        self.root = Path(root).resolve()

    def archive(self, agid: str, key: str, value) -> None:
        atomic_json(safe_child(self.root / "archive", f"{agid}/{key}.json"), value)

    def register(self, agid: str, *, parent: str | None = None, scope: str = ""):
        path = self.root / "directory.json"
        with file_lock(self.root / ".directory.lock"):
            directory = json.loads(path.read_bytes()) if path.exists() else {}
            if parent is not None and parent not in directory:
                raise ValueError("Parent agent must be registered first")
            ancestor = parent
            while ancestor:
                if ancestor == agid:
                    raise ValueError("Agent hierarchy cannot contain a cycle")
                ancestor = directory[ancestor]["parent"]
            directory[agid] = {"parent": parent, "scope": scope}
            atomic_json(path, directory)

    def directory(self):
        path = self.root / "directory.json"
        return json.loads(path.read_bytes()) if path.exists() else {}

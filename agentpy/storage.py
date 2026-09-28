"""Atomic JSON transactions and local process locks (macOS/Linux)."""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import tempfile


def encode(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()


def atomic_json(path: Path, value) -> None:
    atomic_bytes(path, encode(value))


def atomic_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".writing-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def file_lock(path: Path, *, blocking=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def safe_child(root: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError("Expected a relative path")
    path = (root / name).resolve()
    if path == root.resolve() or root.resolve() not in path.parents:
        raise ValueError("Path escapes its store")
    return path


class StateStore:
    def __init__(self, root: Path, limits):
        self.root = root
        self.limits = limits
        self.path = root / "state.json"

    def read(self):
        state = json.loads(self.path.read_bytes())
        if state.get("schema_version") != 1:
            raise ValueError("Unsupported agent state schema")
        return state

    @contextmanager
    def transaction(self):
        with file_lock(self.root / ".state.lock"):
            state = self.read()
            yield state
            self.write(state)

    def write(self, state):
        state["revision"] += 1
        raw = encode(state)
        if len(raw) > self.limits.state_bytes:
            raise ValueError("Active state size limit exceeded; consolidate or remove finished work")
        atomic_bytes(self.path, raw)

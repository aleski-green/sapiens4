"""Atomic JSON transactions and local process locks (Windows/macOS/Linux)."""
from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
import time

if os.name == 'nt':
    import msvcrt
else:
    import fcntl


def encode(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()


def atomic_json(path: Path, value) -> None:
    atomic_bytes(path, encode(value))


def read_bytes(path: Path) -> bytes:
    for attempt in range(101):
        try:
            return path.read_bytes()
        except PermissionError:
            if os.name != 'nt' or attempt == 100:
                raise
            time.sleep(.01)


def atomic_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".writing-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        # Windows readers briefly hold handles without FILE_SHARE_DELETE.
        # Retry sharing violations while retaining the fully flushed temporary file.
        for attempt in range(101):
            try:
                os.replace(temporary, path)
                break
            except PermissionError:
                if os.name != 'nt' or attempt == 100:
                    raise
                time.sleep(.01)
        if os.name != 'nt':  # Windows cannot open a directory through os.open.
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
        lock_file(stream, blocking=blocking)
        try:
            yield
        finally:
            unlock_file(stream)


def lock_file(stream, *, blocking=True):
    if os.name != 'nt':
        return fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
    while True:
        stream.seek(0)
        try:
            # Windows permits locking beyond EOF: no initialization write race.
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            return
        except OSError as error:
            if error.errno not in (13, 36):
                raise
            if not blocking:
                raise BlockingIOError('File is locked by another process') from error
            time.sleep(.05)


def unlock_file(stream):
    if os.name == 'nt':
        stream.seek(0)
        msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        fcntl.flock(stream, fcntl.LOCK_UN)


def safe_child(root: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError("Expected a relative path")
    path = (root / name).resolve()
    if path == root.resolve() or root.resolve() not in path.parents:
        raise ValueError("Path escapes its store")
    return path

"""Shared artifacts, archives, agent directory, and durable mailboxes."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from uuid import uuid4

from .storage import atomic_bytes, atomic_json, file_lock, safe_child


class Corpora:
    def __init__(self, root):
        self.root = Path(root).resolve()

    def put(self, path: str, content: str | bytes) -> str:
        target = safe_child(self.root / "artifacts", path)
        atomic_bytes(target, content.encode() if isinstance(content, str) else content)
        return path

    def read(self, path: str) -> bytes:
        return safe_child(self.root / "artifacts", path).read_bytes()

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

    def send(self, sender: str, recipient: str, text: str, *, reply_to=None, message_id=None) -> str:
        directory = self.directory()
        if sender not in directory or recipient not in directory:
            raise ValueError("Sender and recipient must be registered agents")
        message_id = message_id or uuid4().hex
        message = dict(id=message_id, sender=sender, recipient=recipient, text=text,
                       reply_to=reply_to, time=datetime.now(timezone.utc).isoformat())
        if not self.received(recipient, message_id):
            atomic_json(safe_child(self.root / "mailboxes", f"{recipient}/{message_id}.json"), message)
        return message_id

    def pending(self, recipient):
        directory = safe_child(self.root / "mailboxes", recipient)
        return sorted((json.loads(p.read_bytes()) for p in directory.glob("*.json")),
                      key=lambda row: (row["time"], row["id"]))

    def acknowledge(self, recipient, message_id):
        atomic_json(safe_child(self.root / "receipts", f"{recipient}/{message_id}.json"), True)
        path = safe_child(self.root / "mailboxes", f"{recipient}/{message_id}.json")
        if path.exists():
            path.unlink()

    def received(self, recipient, message_id):
        return safe_child(self.root / "receipts", f"{recipient}/{message_id}.json").exists()

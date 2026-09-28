"""Memory schema and configuration shared by Sapiens4 agent behaviors."""
from __future__ import annotations
import json
import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from .interfaces import LLMSpec

@dataclass
class MemoryEntry:
    kind: str
    content: str
    evidence: str = ""
    salience: float = 0.5
    tags: list[str] = field(default_factory=list)
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def render(self):
        return f"- [{self.kind}] {self.content}"



class FlowConfig:
    memory_schema = MemoryEntry
    spec = LLMSpec()

    def default_spec(self):
        return self.spec

    def parse_memory(self, raw):
        rows = json.loads(raw)
        if not isinstance(rows, list):
            raise ValueError("Memory output must be a JSON list")
        entries = []
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"kind", "content", "evidence", "salience", "tags"}:
                raise ValueError("Invalid memory fields")
            if not isinstance(row["kind"], str) or row["kind"] not in {"fact", "preference", "decision", "open_loop", "skill"}:
                raise ValueError("Invalid memory kind")
            if not isinstance(row["content"], str) or not row["content"].strip() or not isinstance(row["evidence"], str):
                raise ValueError("Memory content and evidence must be strings")
            score = row["salience"]
            if type(score) not in (int, float) or not math.isfinite(score) or not 0 <= score <= 1:
                raise ValueError("Salience must be between 0 and 1")
            if not isinstance(row["tags"], list) or not all(isinstance(tag, str) for tag in row["tags"]):
                raise ValueError("Tags must be strings")
            entries.append(self.memory_schema(**row))
        return entries

"""Small declarations for human-authored agent behavior."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Role:
    prompt: str
    model: str = "default"


@dataclass(frozen=True)
class Flow:
    steps: tuple[str, ...]
    commit: str = "reply"


@dataclass
class Outcome:
    output: str = ""
    logs: list[dict] = field(default_factory=list)
    error: str | None = None

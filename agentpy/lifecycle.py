"""Small declarations for human-authored agent behavior."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Limits:
    max_records: int = 1_000
    state_bytes: int = 1_000_000
    context_chars: int = 60_000
    tokens_per_call: int = 16_000
    tokens_per_loop: int = 128_000
    tokens_per_sprint: int = 1_000_000

    def __post_init__(self):
        if any(type(value) is not int or value <= 0 for value in vars(self).values()):
            raise ValueError("Limits must be positive integers")


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
    tokens: int = 0
    error: str | None = None

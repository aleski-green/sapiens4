"""Model request, role, flow and outcome declarations."""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class LLMSpec:
    """How to construct an LLM worker. Factory-specific keys go in extra."""

    model: str = "default"
    role: str = "worker"
    extra: dict[str, Any] = field(default_factory=dict)


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

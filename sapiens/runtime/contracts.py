"""Model request, role, flow and outcome declarations."""
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class LLMSpec:
    model: str = "default"
    role: str = "worker"


@dataclass(frozen=True)
class Role:
    prompt: str
    model: str = "default"


@dataclass(frozen=True)
class Flow:
    steps: tuple[str, ...]


@dataclass
class Outcome:
    output: str = ""
    logs: list[dict] = field(default_factory=list)
    error: str | None = None

"""Local model worker contracts."""
from __future__ import annotations
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class LLMSpec:
    """How to construct an LLM worker. Factory-specific keys go in extra."""

    model: str = "default"
    role: str = "worker"
    extra: dict[str, Any] = field(default_factory=dict)


@dataclass
class Turn:
    role: str  # user | assistant | system | tool | lambda
    content: str
    ts: str = field(default_factory=_utcnow)
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class SessionLog:
    key: str
    llm_id: str
    spec: LLMSpec
    turns: list[Turn] = field(default_factory=list)

    def render(self) -> str:
        lines = [f"## session:{self.key}  llm={self.llm_id}  role={self.spec.role}"]
        for turn in self.turns:
            lines.append(f"[{turn.role}] {turn.content}")
        return "\n".join(lines)


class LLM(ABC):
    """One worker bound to one session. The backend may keep extra state
    behind .id; AgentPy only stores the transcript in sessions[key]."""

    id: str
    spec: LLMSpec

    @abstractmethod
    def complete(self, prompt: str) -> str: ...


class LLMFactory(ABC):
    @abstractmethod
    def spawn(self, spec: LLMSpec) -> LLM:
        """Brand-new worker / backend session."""

    @abstractmethod
    def iterate(self, session: SessionLog) -> LLM:
        """Rehydrate the worker that owns this session log."""

"""Worker and memory contracts used by the persistent runtime."""
from __future__ import annotations
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Generic, Iterator, Sequence, TypeVar

T = TypeVar("T")

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



class Renderable(ABC):
    @abstractmethod
    def render(self) -> str:
        """Markdown (or plain text) block for LLM context."""



class Memory(Renderable, ABC, Generic[T]):
    """Experience store. Row type is Config.memory_schema."""

    @abstractmethod
    def __iter__(self) -> Iterator[T]: ...

    @abstractmethod
    def add(self, item: T) -> None: ...

    @abstractmethod
    def extend(self, items: Sequence[T]) -> None: ...

    @abstractmethod
    def replace_all(self, items: Sequence[T]) -> None: ...

    @abstractmethod
    def clear(self) -> None: ...



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

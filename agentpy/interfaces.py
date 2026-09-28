"""Local model worker contracts."""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class LLMSpec:
    """How to construct an LLM worker. Factory-specific keys go in extra."""

    model: str = "default"
    role: str = "worker"
    extra: dict[str, Any] = field(default_factory=dict)

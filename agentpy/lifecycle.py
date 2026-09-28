"""Small declarations for human-authored agent behavior."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable
from pathlib import Path


@dataclass(frozen=True)
class Limits:
    max_records: int = 1_000
    state_bytes: int = 1_000_000
    context_chars: int = 60_000
    parallel_jobs: int = 3
    tokens_per_call: int = 16_000
    tokens_per_loop: int = 128_000
    tokens_per_sprint: int = 1_000_000

    def __post_init__(self):
        if any(type(value) is not int or value <= 0 for value in vars(self).values()):
            raise ValueError("Limits must be positive integers")


@dataclass(frozen=True)
class Schedule:
    awake_minutes: int = 10
    circa_hours: int = 24
    sprint_days: int = 7
    timezone: str = "UTC"
    sprint_anchor: str = "2026-01-05"

    def __post_init__(self):
        from datetime import date
        from zoneinfo import ZoneInfo
        if min(self.awake_minutes, self.circa_hours, self.sprint_days) <= 0:
            raise ValueError("Schedule intervals must be positive")
        ZoneInfo(self.timezone)
        date.fromisoformat(self.sprint_anchor)


@dataclass(frozen=True)
class Role:
    prompt: str
    model: str = "default"


class Prompts:
    """Read explicit Markdown prompts beside the config file."""
    def __init__(self, config_file):
        self.root = Path(config_file).resolve().parent / "prompts"

    def __getitem__(self, name):
        return (self.root / f"{name}.md").read_text()


@dataclass(frozen=True)
class Python:
    """A Python transformation between LLM calls; receives a private context."""
    function: Callable
    output: str = "last"


@dataclass(frozen=True)
class Flow:
    steps: tuple[str | Python, ...]
    commit: str = "note"  # reply, memory, morphos, note


def Debate(proposer: str, critic: str, arbiter: str, *, commit: str) -> Flow:
    return Flow((proposer, critic, arbiter), commit=commit)


@dataclass(frozen=True)
class Request:
    flow: str
    task: str = ""
    key: str | None = None


@dataclass(frozen=True)
class Wake:
    """Read-only scheduling facts. A wake-up rule need not call an LLM."""
    now: str
    changed: bool
    circa_due: bool
    due_tasks: tuple[dict, ...] = ()


@dataclass(frozen=True)
class MorphPolicy:
    """Host-owned policy, supplied separately from adaptive Config."""
    editable: tuple[str, ...] = ("config.py", "behaviors.py", "prompts/*.md")
    checks: tuple[tuple[str, ...], ...] = ()
    timeout_seconds: int = 30
    max_file_bytes: int = 100_000


@dataclass
class Outcome:
    output: str = ""
    logs: list[dict] = field(default_factory=list)
    tokens: int = 0
    error: str | None = None

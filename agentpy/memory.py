"""Typed memory view over the persistent agent's saved records."""
from __future__ import annotations
from dataclasses import asdict, dataclass, field, is_dataclass
from json import dumps
from typing import Iterator, Sequence
from .interfaces import Memory, T

@dataclass
class ListMemory(Memory[T]):
    schema: type
    items: list[T] = field(default_factory=list)

    def __iter__(self) -> Iterator[T]:
        return iter(self.items)

    def add(self, item: T) -> None:
        if not isinstance(item, self.schema):
            raise TypeError(f"memory row must be {self.schema.__name__}, got {type(item).__name__}")
        self.items.append(item)

    def extend(self, items: Sequence[T]) -> None:
        for item in items:
            self.add(item)

    def replace_all(self, items: Sequence[T]) -> None:
        self.items = []
        self.extend(items)

    def clear(self) -> None:
        self.items = []

    def render(self) -> str:
        if not self.items:
            return "(empty)"
        blocks = []
        for item in self.items:
            render = getattr(item, "render", None)
            if callable(render):
                blocks.append(render())
            elif is_dataclass(item) and not isinstance(item, type):
                blocks.append(dumps(asdict(item), ensure_ascii=False))
            else:
                blocks.append(str(item))
        return "\n".join(blocks)

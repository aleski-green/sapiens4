"""Bounded local Codex processes and their public JSONL lifecycle events."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
import signal
from pathlib import Path
import subprocess
from threading import Event, Thread
from time import monotonic, time
from typing import Any, Callable
from uuid import uuid4

from sapiens.runtime.contracts import LLMSpec
from sapiens.runtime.settings import codex_binary, model_defaults


EventSink = Callable[[str], None]


def _print_event(message: str) -> None:
    print(message, flush=True)


@dataclass
class CodexLLM:
    """One resumable local ``codex exec`` thread."""

    spec: LLMSpec
    workdir: Path
    id: str = field(default_factory=lambda: f"pending_{uuid4().hex[:8]}")
    resume: bool = False
    reasoning_effort: str | None = None
    event_sink: EventSink = _print_event
    timeout_seconds: float | None = None
    cancel_event: Event = field(default_factory=Event, repr=False)
    activity: dict = field(default_factory=dict)
    _tools: dict = field(default_factory=dict, repr=False)

    def complete(self, prompt: str) -> str:
        if self.timeout_seconds is not None and self.timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if self.cancel_event.is_set():
            raise InterruptedError('Stopped before starting the model')
        self.activity = dict(started=time()*1000, updated=time()*1000, phase='Waiting for model', last_action='')
        self._tools.clear()
        command = self._command(prompt)
        final_message: str | None = None
        recent_output: list[str] = []
        stderr_output: list[str] = []

        process = subprocess.Popen(
            command,
            cwd=self.workdir,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        assert process.stdout is not None
        assert process.stderr is not None

        def drain_stderr() -> None:
            for stderr_line in process.stderr:
                stderr_output.append(stderr_line.rstrip())
                del stderr_output[:-20]

        stderr_thread = Thread(target=drain_stderr, daemon=True)
        stderr_thread.start()

        finished, timed_out = Event(), Event()

        def stop_process() -> None:
            if process.returncode is not None:
                return
            # Freeze and collect descendants before killing: command tools may
            # create their own process groups. Never reap the root before this.
            pending, stopped = {process.pid}, set()
            try:
                while pending:
                    for pid in pending:
                        try:
                            os.kill(pid, signal.SIGSTOP)
                        except ProcessLookupError:
                            pass
                    stopped.update(pending)
                    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True, timeout=2)
                    pending = {int(pid) for pid, parent in map(str.split, rows.splitlines())
                               if int(parent) in stopped} - stopped
            finally:
                for pid in reversed(sorted(stopped)):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

        def watch() -> None:
            deadline = monotonic() + self.timeout_seconds if self.timeout_seconds is not None else float('inf')
            while not finished.wait(.05):
                if self.cancel_event.is_set() or monotonic() >= deadline:
                    if not self.cancel_event.is_set():
                        timed_out.set()
                    stop_process()
                    return

        watcher = Thread(target=watch, daemon=True)
        watcher.start()
        try:
            for raw_line in process.stdout:
                line = raw_line.rstrip()
                if not line:
                    continue
                recent_output.append(line)
                recent_output = recent_output[-20:]
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    self.event_sink(f"[codex] {line}")
                    continue
                message = self._consume_event(event)
                if event.get("type") == "turn.failed":
                    raise RuntimeError(f"Codex turn failed: {event}")
                if message is not None:
                    final_message = message
            returncode = process.wait()
        finally:
            finished.set()
            watcher.join()
            try:
                stop_process()
            finally:
                returncode = process.wait()
                stderr_thread.join(timeout=2)
                process.stdout.close()
                process.stderr.close()
        if self.cancel_event.is_set():
            raise InterruptedError('Stopped by Admin; review external effects before retrying')
        if timed_out.is_set():
            detail = "\n".join(stderr_output[-5:])
            raise TimeoutError(
                f"Codex exceeded {self.timeout_seconds}s; its process tree was stopped. "
                f"Session: {self.id}.\n{detail}"
            )
        if returncode != 0:
            detail = "\n".join([*stderr_output, *recent_output])
            raise RuntimeError(f"codex exec failed (exit {returncode}):\n{detail}")
        if final_message is None:
            raise RuntimeError("Codex completed without an agent message.")
        return final_message

    def _command(self, prompt: str) -> list[str]:
        executable = codex_binary()
        if not executable:
            raise RuntimeError("Codex CLI was not found. Install Codex and run codex login.")
        model, reasoning = model_defaults()
        defaults = ['-c', 'model_reasoning_effort=' + json.dumps(self.reasoning_effort or reasoning)]
        if self.spec.model == 'default':
            defaults += ['-c', 'model=' + json.dumps(model)]
        common = ["--json", "--dangerously-bypass-approvals-and-sandbox"]
        if self.spec.model != "default":
            common += ["--model", self.spec.model]
        command = [executable, "exec", *defaults, "--skip-git-repo-check"]
        if self.resume:
            return [*command, "resume", *common, self.id, prompt]
        return [*command, *common, "--cd", str(self.workdir), "--color", "never", prompt]

    def _consume_event(self, event: dict[str, Any]) -> str | None:
        event_type = event.get("type")
        item = event.get('item', {})
        if item.get('type') in {'command_execution', 'mcp_tool_call', 'web_search', 'file_change'}:
            label = str(item.get('command') or item.get('tool') or item['type'])[:200]
            if event_type == 'item.started':
                self._tools[item.get('id', label)] = label
            elif event_type == 'item.completed':
                self._tools.pop(item.get('id', label), None)
                self.activity = {**self.activity, 'last_action': label}
        self.activity = {**self.activity, 'updated': time()*1000,
                         'phase': 'Running tool' if self._tools else 'Waiting for model',
                         'tool': next(iter(self._tools.values()), '')}

        if event_type == "thread.started":
            self.id = event["thread_id"]
            self.event_sink(f"🧵 Codex thread {self.id} started")
        elif event_type == "turn.started":
            self.event_sink("🧠 Codex is working…")
        elif event_type == "turn.completed":
            self.event_sink("✅ Codex turn completed")
        elif event_type in {"turn.failed", "error"}:
            self.event_sink(f"❌ Codex error: {event.get('message', event)}")
        elif event_type in {"item.started", "item.completed"}:
            return self._consume_item(event.get("item", {}), completed=event_type.endswith("completed"))

        return None

    def _consume_item(self, item: dict[str, Any], *, completed: bool) -> str | None:
        item_type = item.get("type")
        marker = "finished" if completed else "started"

        if item_type == "agent_message" and completed:
            text = item.get("text", "")
            self.event_sink(f"🤖 Codex response\n{text}")
            return text
        if item_type == "reasoning" and completed:
            text = item.get("text") or item.get("summary")
            if text:
                self.event_sink(f"💭 Reasoning summary\n{text}")
        elif item_type == "command_execution":
            command = item.get("command", "")
            self.event_sink(f"🛠️ Command {marker}: {command}")
        elif item_type == "file_change":
            self.event_sink(f"📝 File change {marker}")
        elif item_type == "mcp_tool_call":
            tool = item.get("tool", item.get("name", "unknown"))
            self.event_sink(f"🔌 MCP call {marker}: {tool}")
        elif item_type == "web_search":
            self.event_sink(f"🔎 Web search {marker}")
        elif item_type == "plan" and completed:
            text = item.get("text")
            if text:
                self.event_sink(f"📋 Plan\n{text}")

        return None


@dataclass
class CodexFactory:
    """Create unrestricted local Codex CLI sessions."""

    workdir: Path = field(default_factory=Path.cwd)
    event_sink: EventSink = _print_event
    timeout_seconds: float | None = None

    execution: Callable | None = None

    def spawn(self, spec: LLMSpec) -> CodexLLM:
        policy = self.execution() if self.execution else dict(mode='normal', timeout_seconds=300)
        return CodexLLM(spec=spec, workdir=self.workdir, event_sink=self.event_sink,
            timeout_seconds=min(self.timeout_seconds or policy['timeout_seconds'], policy['timeout_seconds']),
            reasoning_effort='xhigh' if policy['mode'] == 'deep' else model_defaults()[1])

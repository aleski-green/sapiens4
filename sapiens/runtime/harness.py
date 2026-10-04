"""Bounded, switchable local harness processes and lifecycle events."""

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

from sapiens.runtime.contracts import LLMSpec, RUN_TIMEOUT_SECONDS
from sapiens.runtime.settings import harness_binary, harness_name, model_defaults


@dataclass
class HarnessLLM:
    """One local Kimi or Codex call; the host supplies conversation context."""

    spec: LLMSpec
    workdir: Path
    id: str = field(default_factory=lambda: f"pending_{uuid4().hex[:8]}")
    resume: bool = False
    reasoning_effort: str | None = None
    timeout_seconds: float | None = RUN_TIMEOUT_SECONDS
    cancel_event: Event = field(default_factory=Event, repr=False)
    activity: dict = field(default_factory=dict)
    provider: str = field(default_factory=harness_name)
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

        environment = os.environ.copy()
        if self.provider == 'kimi':
            environment['KIMI_MODEL_THINKING_EFFORT'] = self.reasoning_effort or model_defaults('kimi')[1]
        process = subprocess.Popen(
            command,
            cwd=self.workdir,
            env=environment,
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
                    continue
                message = self._consume_event(event)
                if event.get("type") == "turn.failed":
                    raise RuntimeError(f"{self.provider} turn failed: {event}")
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
                f"{self.provider} exceeded {self.timeout_seconds}s; its process tree was stopped. "
                f"Session: {self.id}.\n{detail}"
            )
        if returncode != 0:
            detail = "\n".join([*stderr_output, *recent_output])
            raise RuntimeError(f"{self.provider} harness failed (exit {returncode}):\n{detail}")
        if final_message is None:
            raise RuntimeError(f"{self.provider} completed without an agent message.")
        return final_message

    def _command(self, prompt: str) -> list[str]:
        executable = harness_binary(self.provider)
        if not executable:
            raise RuntimeError(f"{self.provider} CLI was not found. Install and configure it before starting a call.")
        model, reasoning = model_defaults(self.provider)
        if self.provider == 'kimi':
            if self.resume:
                raise ValueError('Kimi calls use host-prepared context; resuming a harness session is unsupported.')
            return [executable, '-p', prompt, '--model', model if self.spec.model == 'default' else self.spec.model,
                    '--output-format', 'stream-json']
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
        if self.provider == 'kimi':
            role = event.get('role')
            if role == 'meta':
                if event.get('type') == 'session.start' and event.get('session_id'):
                    self.id = event['session_id']
                return None
            if role not in {'assistant', 'tool'}:
                raise RuntimeError(f'Unexpected Kimi stream message: {event}')
            if role == 'tool':
                label = self._tools.pop(event.get('tool_call_id'), '')
                self.activity = {**self.activity, 'last_action': label}
            else:
                for call in event.get('tool_calls') or []:
                    self._tools[call['id']] = str(call.get('function', {}).get('name', 'tool'))
            self.activity = {**self.activity, 'updated': time()*1000,
                             'phase': 'Running tool' if self._tools else 'Waiting for model',
                             'tool': next(iter(self._tools.values()), '')}
            if role == 'assistant' and not event.get('tool_calls'):
                content = event.get('content')
                if isinstance(content, list):
                    content = ''.join(block.get('text', '') for block in content if block.get('type') == 'text')
                return content if isinstance(content, str) else None
            return None
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
        elif event_type == "item.completed" and item.get("type") == "agent_message":
            return item.get("text", "")
        return None


@dataclass
class HarnessFactory:
    """Create local calls for the selected harness."""

    workdir: Path = field(default_factory=Path.cwd)
    execution: Callable | None = None

    def spawn(self, spec: LLMSpec) -> HarnessLLM:
        policy = self.execution() if self.execution else dict(mode='normal')
        return HarnessLLM(spec=spec, workdir=self.workdir,
            reasoning_effort=('max' if harness_name() == 'kimi' else 'xhigh') if policy['mode'] == 'deep' else model_defaults()[1])

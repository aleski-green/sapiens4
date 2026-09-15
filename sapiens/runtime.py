"""Load the pinned SDK and configure the host's two user-facing flows."""
from pathlib import Path
from functools import lru_cache
import os
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SDK = ROOT / "lab-sapiens-rnd"
if not (SDK / "agentpy").is_dir():
    raise RuntimeError("Missing SDK. Run: git submodule update --init --recursive")
sys.path.insert(0, str(SDK))

from agentpy import AgentPy, Flow, Limits  # noqa: E402
from agentpy_codex import CodexFactory, CodexLLM  # noqa: E402
from config import Config as SDKConfig  # noqa: E402


class Config(SDKConfig):
    # Computer-task answers become conversation history as well as durable jobs.
    flows = {**SDKConfig.flows, "computer": Flow(("react",), commit="reply")}


@lru_cache(maxsize=1)
def codex_binary():
    """Choose the newest installed CLI; an explicit app-local override wins."""
    override = os.environ.get("SAPIENS_CODEX_BINARY")
    if override:
        return shutil.which(override)
    candidates = [shutil.which("codex")]
    if sys.platform == "darwin":
        candidates += [f"/Applications/{app}.app/Contents/Resources/codex" for app in ("Codex", "ChatGPT")]
    versions = []
    for path in dict.fromkeys(p for p in candidates if p and os.access(p, os.X_OK)):
        try:
            result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=5)
            match = re.search(r"(\d+)\.(\d+)\.(\d+)", result.stdout)
            if result.returncode == 0 and match:
                versions.append((tuple(map(int, match.groups())), path))
        except (OSError, subprocess.TimeoutExpired):
            continue
    return max(versions, default=((), None))[1]


class LocalLLM(CodexLLM):
    def _command(self, prompt):
        command = super()._command(prompt)
        executable = codex_binary()
        if not executable:
            raise RuntimeError("Codex CLI was not found. Install Codex and run codex login.")
        command[0] = executable
        command.insert(2, "--skip-git-repo-check")
        return command


class LocalFactory(CodexFactory):
    def spawn(self, spec):
        return LocalLLM(spec=spec, workdir=self.workdir, event_sink=self.event_sink,
                        timeout_seconds=self.timeout_seconds)


def computer_manifest(binary):
    command = shlex.quote(str(binary))
    return f"""Computer and browser interaction uses Blindly4 as the main tool.
Run {command} schema before first use to discover its current commands.
Use this absolute executable path for all Blindly4 calls: {command}
Read its JSON results and check exit codes. Exit 77 means Accessibility permission
is unavailable; report this and stop. Never substitute a different computer-use
tool or claim success when Blindly4 cannot access the requested application.
Rediscover live AX paths immediately before mutations and pass --pid for input.
For sending messages, use paste --target-path followed by press with
--require-value-path and --require-value, bound to the exact intended draft.
External commits must be within the user's explicitly requested task.
Do not use bare type/key-return to send messages or weaken Blindly4's checks.
The host serializes jobs, giving one Sapi at a time access to the shared computer.
In ordinary chat, follow the conversation role's text-only instruction.
Only computer-task requests authorize tool execution. Do not edit the app's
SQLite database, agent state.json, or the integration source to perform a task.
"""

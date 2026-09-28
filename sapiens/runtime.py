"""Configure Sapiens4 flows using the repository-owned runtime."""
import json
import shlex
import sys

from .codex_config import codex_binary, model_defaults
from .foreground import ForegroundReturn
from .paths import ROOT
from .prompts import prompt
from .sdk import CodexFactory, CodexLLM, Flow, Role


class Config:
    flows = {"chat": Flow(("conversation",)), "computer": Flow(("conversation",))}
    roles = {"conversation": Role(prompt("conversation"))}


class LocalLLM(CodexLLM):
    def complete(self, prompt):
        foreground = ForegroundReturn(self.workdir)
        self.warning = None
        try:
            return super().complete(prompt)
        finally:
            finish = getattr(self, 'finish_computer', None)
            self.warning = finish(foreground.restore) if finish else foreground.restore()
            if self.warning:
                self.event_sink(self.warning)

    def _command(self, prompt):
        command = super()._command(prompt)
        executable = codex_binary()
        if not executable:
            raise RuntimeError("Codex CLI was not found. Install Codex and run codex login.")
        command[0] = executable
        command.insert(2, "--skip-git-repo-check")
        # Apply host defaults to every role, including resumed calls.
        # Explicit SDK models still take precedence over the default model.
        model, reasoning = model_defaults()
        defaults = ['-c', 'model_reasoning_effort=' + json.dumps(reasoning)]
        if self.spec.model == 'default':
            defaults += ['-c', 'model=' + json.dumps(model)]
        command[2:2] = defaults
        return command


class LocalFactory(CodexFactory):
    def spawn(self, spec):
        llm = LocalLLM(spec=spec, workdir=self.workdir, event_sink=self.event_sink)
        if hasattr(self, 'finish_computer'):
            llm.finish_computer = self.finish_computer
        return llm


def computer_manifest(binary):
    launcher = ' '.join(shlex.quote(str(p)) for p in (sys.executable, ROOT / 'sapiens/computer.py'))
    return prompt('computer-use', launcher=launcher, binary=shlex.quote(str(binary)))

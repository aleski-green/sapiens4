"""Verify harness compatibility and a real model call before installing code."""
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from sapiens.runtime.settings import MIN_CODEX_VERSION, cli_version, codex_binary, harness_binary, harness_name, model_defaults
from sapiens.prompts import prompt
from sapiens.runtime.harness import HarnessLLM
from sapiens.runtime.contracts import LLMSpec


@dataclass
class ModelProbe(HarnessLLM):
    executable: str = ''
    reasoning: str = ''

    def _command(self, prompt):
        if self.provider == 'kimi':
            return super()._command(prompt)
        return [self.executable, 'exec', '--json', '--ephemeral',
                '--sandbox', 'read-only', '--skip-git-repo-check',
                '--cd', str(self.workdir), '-c', 'approval_policy="never"',
                '-c', 'model=' + json.dumps(self.spec.model),
                '-c', 'model_reasoning_effort=' + json.dumps(self.reasoning), prompt]


def check():
    provider = harness_name()
    if provider == 'kimi':
        binary = harness_binary(provider)
        if not binary:
            raise RuntimeError('Kimi CLI was not found. Install Kimi Code CLI and configure a K3 model alias.')
        version = subprocess.run([binary, '--version'], capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        model, reasoning = model_defaults()
        with tempfile.TemporaryDirectory(prefix='sapiens-preflight-') as directory:
            probe = HarnessLLM(LLMSpec(model=model), Path(directory), timeout_seconds=90, reasoning_effort=reasoning)
            try:
                answer = probe.complete(prompt('preflight'))
            except (OSError, RuntimeError, TimeoutError) as error:
                raise RuntimeError(f'Kimi model check failed; installation has not been activated. Details: {error}') from error
            if answer.strip() != 'SAPIENS_PREFLIGHT_OK':
                raise RuntimeError('Kimi model check returned an unexpected reply.')
        return dict(provider=provider, binary=binary, version=version, model=model, reasoning=reasoning)
    binary = codex_binary()
    if not binary:
        raise RuntimeError('Codex CLI was not found. Install @openai/codex and run codex login. '
                           'Check SAPIENS_CODEX_BINARY if it is set.')
    version = cli_version(binary)
    if version < MIN_CODEX_VERSION:
        required = '.'.join(map(str, MIN_CODEX_VERSION))
        actual = '.'.join(map(str, version))
        raise RuntimeError(f'Codex CLI {actual} at {binary} is too old; Sapiens4 requires '
                           f'{required} or newer. Update it (npm install -g @openai/codex@latest) '
                           'and rerun this check.')
    login = subprocess.run([binary, 'login', 'status'], capture_output=True, text=True, timeout=10)
    if login.returncode:
        raise RuntimeError(f'Codex is not signed in. Run {binary} login and rerun this check.')
    model, reasoning = model_defaults()
    with tempfile.TemporaryDirectory(prefix='sapiens-preflight-') as directory:
        probe = ModelProbe(spec=LLMSpec(model=model), workdir=Path(directory),
                           executable=binary, reasoning=reasoning, timeout_seconds=90)
        try:
            answer = probe.complete(prompt('preflight'))
        except (OSError, RuntimeError, TimeoutError) as error:
            raise RuntimeError(f'Codex model check failed for {model} / {reasoning} using {binary}. '
                               'Confirm model access for this login and client; '
                               f'installation has not been activated. Details: {error}') from error
        if answer.strip() != 'SAPIENS_PREFLIGHT_OK':
            raise RuntimeError(f'Codex model check for {model} / {reasoning} returned an unexpected reply.')
    return dict(provider=provider, binary=binary, version='.'.join(map(str, version)), model=model, reasoning=reasoning)


def main():
    try:
        result = check()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Sapiens4 preflight failed: {error}', file=sys.stderr)
        return 1
    print(f"{result['provider']} {result['version']}: {result['model']} / {result['reasoning']} verified "
          f"({result['binary']})")
    return 0


if __name__ == '__main__':
    sys.exit(main())

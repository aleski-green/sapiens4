"""Single import boundary for the pinned, source-only AgentPy dependency.

Host modules import SDK symbols here, so none depends on another host module
being imported first to configure Python's search path.
"""
import sys

from .paths import SDK

if not (SDK / 'agentpy').is_dir():
    raise RuntimeError('Missing SDK. Run: git submodule update --init --recursive')
if str(SDK) not in sys.path:
    sys.path.insert(0, str(SDK))

from agentpy import Flow, Limits, Role, Request  # noqa: E402
from agentpy.interfaces import LLMSpec  # noqa: E402
from agentpy.lifecycle import Outcome, Python  # noqa: E402
from agentpy.runtime import PersistentAgent  # noqa: E402
from agentpy.storage import atomic_bytes  # noqa: E402
from agentpy_codex import CodexFactory, CodexLLM  # noqa: E402
from config import Config as SDKConfig  # noqa: E402

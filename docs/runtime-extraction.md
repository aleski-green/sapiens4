> Historical extraction record. Later refactors removed scheduling, tasks, structured memory, adaptive behavior and the memory-tree UI. Owned Python now lives under `sapiens/{corpora,runtime,computer}` and web source under `web/{shell,features,theme}`. See [current reference](reference.md) and [code guidelines](../CONTRIBUTING.md).

# Runtime source boundaries

Sapiens4 owns the code it executes. Blindly4 remains its only Git submodule.

| Source | Runtime code retained here |
| --- | --- |
| `lab-sapiens-rnd` at `c9633927af12dff8656e730941a5249814839af4` | `agentpy/`: persistent agent, storage and locking, corpora, scheduling declarations, adaptive configuration validation, typed memory, Codex worker, default configuration and its prompts |
| `lab-corpora-ui` at `aa8a0997ee3ecc4dc79986204c328fd16176dc8e` | `web/workspace/`, `web/assets/` and `web/memory-tree.*`: live shell, workspace tabs, themes, avatar renderer and memory tree |

The extraction excludes notebooks, human specifications, Jupyter launchers,
standalone AgentPy CLI/launchd tooling, the synchronous experimental agent,
its pipeline and adversarial demo, and unused dataclass persistence. Runtime
persistence and Codex subprocess tests now run in the main `tests/` suite.

The UI excludes portable prototype builds, example pages, fixture payloads,
simulated chats/tasks/computer controls, and the JSON tree's example editor.
The existing API controls in `web/` remain responsible for live behavior.

At extraction time, the `agentpy` namespace supported saved adaptive behavior.
Those behaviors and that Python package have since been removed. The `agentpy/`
directory inside user data still holds existing states and archives; the source
reorganization does not move that data, SQLite, artifacts or public HTTP URLs.
The lab repositories remain available in Git history.

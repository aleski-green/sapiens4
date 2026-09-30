# Code guidelines

## rTernarity: structure by responsibility

Developers and coding agents must organize each architectural split into **three
meaningful child responsibilities**, applying the same rule recursively when a
child needs subdivision. Name parts for their purpose; keep related code together.

Functional requirements take precedence: use more branches when the domain needs
them, and briefly explain that choice in the change description. A cohesive
collection may contain any number of file leaves (for example, prompts or tests).
Entry points, package markers, tool-required paths, and external dependencies keep
their required shape. Files are real leaves; do not create empty folders, wrappers,
or speculative code to simulate infinite recursion or satisfy a count.

Refactors must preserve behavior and avoid import cycles. Verify meaningful
boundaries with focused tests; check the three-child invariant only for structures
explicitly modeled as ternary, not every filesystem directory. Expand recursive
visualizations only to the depth needed for the current view.

The owned source roots are `sapiens/` (behavior), `web/` (presentation), and
`macos/` (native app and distribution). Python responsibilities are `corpora/`,
`runtime/`, and `computer/`; CORPORA divides into `sapis/`, `browser.py`, and
`host/`. Web responsibilities are `shell/`, `features/`, and `theme/`.

Runtime accepts state and prepared context; it must not import CORPORA or desktop
code. The host composes these responsibilities. Sapi persistence may use runtime
contracts, but cannot import execution or host implementations. Keep shared file,
clock, path, prompt and validation primitives independent of their consumers.
The recursive checks in `tests/test_import_architecture.py` enforce these boundaries.

`sapiens/assets.py`, `service.py`, and `server.py` are public compatibility
entrypoints for already-installed macOS updaters and rollback. Keep them as small
re-exports; new code imports `corpora/host/` directly. Persistent `agentpy/` data
paths remain unchanged even though the old Python package is removed.

## Hardcoded model prompts

All hardcoded model prompts must live in the repository's root `prompts/`
directory as separate, descriptively named `.md` files, such as
`prompts/conversation.md` and `prompts/computer-use.md`.

Application code must load these files instead of embedding prompt text in source
code. This includes system instructions, prompt prefixes/suffixes, reference
wrappers, and installer model-check prompts. Dynamic values may be inserted using
template placeholders; user messages, Notes contents, and generated state are data,
not hardcoded prompts.

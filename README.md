# Sapiens4

Local conversational agents with CORPORA UI, Codex CLI and Blindly4 computer access. Each Sapi manages a linked HTML notes wiki. SQLite stores UI data.

Chat, Notes, workspaces, and [delegation](documentation/delegation.md) are active. Tasks has Upcoming and Past lists; opening a task shows its YAML body and result. Jobs, cron, task graphs, and memory consolidation remain inactive.

## Core principles

core_principles_sapiens4.md

> Agentic systems now:

“a reactive, agreeable, passive, submissive calculator designed to please humans rather than immediately enhance team efficiency”

> Three distinctive principles of Sapiens4:

I. Proactivity: to be autonomously curious and proactively align itself with an admin-in-the-loop and human teams by initiating Q&A sessions and briefings to actively gather requirements and use those as a chance to challenge them

II. Self-Reflection: to be aware of its own capabilities, flaws, successes, and failures and learn from its own experience and propose its own improvements with low-stakes experiments and tests

III. Decisiveness: to maintain its own integrity, hold qualified opinions and doubts, and possess learned principles, strategies, how-tos, and know-how that may prove stronger and wiser than those derived from human team requirements

## Start

The runtime and UI live in this repo; Blindly4 is the only submodule.

Requires Python 3.9+, Git and authenticated Codex CLI 0.156.1+; Blindly4 requires macOS 13+, Swift 6 and Accessibility permission.

```sh
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
./start.sh --open
```

Open http://127.0.0.1:4174/workspace/.

For a dedicated macOS window and Dock icon, see [the desktop app](macos/README.md).

For a keyboard-only terminal connected to the same running app, run `./sapiens4`.
Use `./sapiens4 status`, `./sapiens4 show`, or `./sapiens4 help` for individual commands.
See [terminal commands and output formats](documentation/specs/CLI.md).

[Architecture notation and analysis](documentation/specs/SapiensSpecNotation.md) · [Haskell specification](documentation/specs/SapiensSpecNotation.hs) · [WorkGraph design](documentation/specs/WorkGraph.md)

[Setup, features, API and tests](documentation/reference.md)

[Contributing and code guidelines](CONTRIBUTING.md)

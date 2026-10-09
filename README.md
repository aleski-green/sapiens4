# Sapiens4

This is a modified fork of [aleski-green/sapiens4](https://github.com/aleski-green/sapiens4), maintained at [fatmahalqaisi-code/sapiens4](https://github.com/fatmahalqaisi-code/sapiens4). One repository supports **macOS 13+ and Windows 10/11**: the Python runtime and web UI are shared, with native Swift/WebKit and C#/WebView2 desktop apps. The Windows port adds native Blindly4 UI Automation, portable ARM64/x64 packages, an app icon and browser theme synchronization.

Local conversational agents with CORPORA UI, Codex CLI and Blindly4 computer access. Each Sapi manages a linked HTML notes wiki. SQLite stores UI data.

Chat, Groups, shared tasks, Notes, workspaces, and [delegation](documentation/delegation.md) are active. Tasks has Upcoming and Past lists; opening a task shows its YAML body and result. Personal chat uses a global Pulse clock: messages batch every two `bpm60` pulses,
with two `chatInput` slots and two `chatOutput` rendering slots per Sapi. Updates
shows only pulses that dispatch calls. Jobs, user cron automation, task graphs,
and memory consolidation remain inactive.

## Core principles

core_principles_sapiens4.md

> Agentic systems now:

“a reactive, agreeable, passive, submissive calculator designed to please humans rather than immediately enhance team efficiency”

> Three distinctive principles of Sapiens4:

I. Proactivity: to be autonomously curious and proactively align itself with an admin-in-the-loop and human teams by initiating Q&A sessions and briefings to actively gather requirements and use those as a chance to challenge them

II. Self-Reflection: to be aware of its own capabilities, flaws, successes, and failures and learn from its own experience and propose its own improvements with low-stakes experiments and tests

III. Decisiveness: to maintain its own integrity, hold qualified opinions and doubts, and possess learned principles, strategies, how-tos, and know-how that may prove stronger and wiser than those derived from human team requirements

## Start

**Windows 10/11:** native ARM64 and x64 desktop packages, PowerShell startup and
Windows UI Automation support are described in [Windows setup](windows/README.md).
Extract a package and run `Sapiens4.exe`, or run `.\start.ps1 -Open` from source.

The runtime and UI live in this repo; Blindly4 is the only submodule.

Source startup requires Python 3.9+, Git and authenticated Codex CLI 0.156.1+.
On macOS, Blindly4 requires macOS 13+, Swift 6 and Accessibility permission. Windows
builds use .NET SDK 10; portable packages bundle Python, .NET and Blindly4.

```sh
git clone --recurse-submodules https://github.com/fatmahalqaisi-code/sapiens4.git
cd sapiens4
./start.sh --open
```

Open http://127.0.0.1:4174/workspace/.

For a dedicated macOS window and Dock icon, see [the desktop app](macos/README.md).

For a keyboard-only terminal connected to the same running app, install terminal support with
`python3 -m pip install --user -r requirements-cli.txt`, then run `./sapiens4`.
Use `./sapiens4 status`, `./sapiens4 show`, or `./sapiens4 help` for individual commands.
See [terminal commands and output formats](documentation/specs/CLI.md).

[Architecture notation and analysis](documentation/haskell-notation-specs/SapiensSpecNotation.md) · [Haskell specification](documentation/haskell-notation-specs/SapiensSpecNotation.hs) · [System Pulsation](documentation/haskell-notation-specs/SystemPulsation.hs) · [WorkGraph design](documentation/specs/WorkGraph.md)

[Setup, features, API and tests](documentation/reference.md)

[Contributing and code guidelines](CONTRIBUTING.md)


## License

Sapiens4 is source-available under the [Sustainable Use License 1.0](license/LICENSE.md).
See [licensing and commercial services](license/LICENSING.md) for community use,
contributions, and future enterprise additions. Commercial inquiries:
[license@sapiens4.ai](mailto:license@sapiens4.ai).

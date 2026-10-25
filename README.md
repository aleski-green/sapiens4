# Sapiens4

Sapiens4 supports **macOS 13+ and Windows 10/11**. Both operating systems use the same Python runtime and web UI, with native desktop apps and Blindly4 computer access.

| Operating system | Desktop app | Computer access | Setup |
| --- | --- | --- | --- |
| macOS 13+ | Swift / WebKit | Apple Accessibility | [macOS setup](macos/README.md) |
| Windows 10/11, ARM64 and x64 | C# / WebView2 | Microsoft UI Automation | [Windows setup](windows/README.md) |

Windows support was contributed through the [fatmahalqaisi-code/sapiens4 fork](https://github.com/fatmahalqaisi-code/sapiens4), including portable packages, an app icon and browser theme synchronization.

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

The runtime and UI live in this repo. Blindly4 provides native computer access;
[libs4](https://github.com/aleski-green/libs4) owns third-party dependencies,
lockfiles, and prebuilt browser libraries. Both are pinned Git submodules. Existing checkouts can fetch
them with `git submodule update --init --recursive`. The UI is written in PureScript
with Halogen; see [UI architecture](documentation/ui.md). Building from source requires
Node.js 22.5+ and npm to install the pinned compiler and dependencies. Startup scripts
build the UI when its sources change. Packaged apps need no Node installation; the
relay image builds its UI in a separate Node stage.

Source startup requires Python 3.9+, Git and authenticated Codex CLI 0.156.1+.
Blindly4 source builds require stable Rust. On macOS, it requires macOS 13+,
Command Line Tools and Accessibility permission. Windows builds also use .NET
SDK 10 and MSVC C++ build tools; portable packages bundle Python, .NET and Blindly4.

**macOS source startup:**

```sh
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
./start.sh --open
```

Open http://127.0.0.1:4174/workspace/.

For a dedicated macOS window and Dock icon, see [the desktop app](macos/README.md).

[Architecture notation and analysis](documentation/haskell-notation-specs/SapiensSpecNotation.md) · [Haskell specification](documentation/haskell-notation-specs/SapiensSpecNotation.hs) · [System Pulsation](documentation/haskell-notation-specs/SystemPulsation.hs) · [WorkGraph design](documentation/specs/WorkGraph.md)

[Setup, features, API and tests](documentation/reference.md)

The header corpora menu switches between local workspaces (Mac/Windows) and saved
remote connections. Switching changes only the interface; Pause and Activate are
separate controls. Saved snapshots open immediately as **Offline**
until the host responds. Without a saved snapshot, an unreachable destination
leaves the current selection open. Pause interrupts running work without replaying
completed actions. Drafts and layout are remembered on the viewing device.

On phones and tablets, add Sapiens4 to the Home Screen and open that app before
choosing **Connect remote corpora**. Scan/upload or paste the invitation from the
host's **Remote control** menu, then approve the matching code there. Linux and
mobile clients offer remote corpora only. Each corpora trusts one remote device;
adding a different corpora preserves the connections already saved on this client.

**Edit** prepares a message for the selected corpora's ChiefSapi, with its name,
device display name, and scope of work. ChiefSapi applies requested changes through
the corpora API. Archived corpora are paused and hidden unless requested.

[Remote control MVP: QR pairing and self-hosted encrypted relay](documentation/specs/RemoteMVP.md)

[Contributing and code guidelines](CONTRIBUTING.md)


## License

Sapiens4 is source-available under the [Sustainable Use License 1.0](license/LICENSE.md).
See [licensing and commercial services](license/LICENSING.md) for community use,
contributions, and future enterprise additions. Commercial inquiries:
[license@sapiens4.ai](mailto:license@sapiens4.ai).

# Sapiens4

Local conversational agents with Chat, Groups, tasks, Notes, native browser
workspaces and remote access. Codex CLI runs model calls; Blindly4 provides
computer access. Sapiens4 is built around proactivity, self-reflection and
independent judgment with human oversight.

## Start

| Platform | Setup |
| --- | --- |
| macOS 13+ | [Build and run the desktop app](osspecific/macos/README.md) |
| Windows 10/11, ARM64 or x64 | [Portable packages and source setup](osspecific/windows/README.md) |
| Remote browser or mobile app | [Pairing and relay setup](documentation/remote.md) |

Source builds require GHC 9.14.1, Cabal 3.18.2, Git, authenticated Codex CLI
0.156.1+, stable Rust, Node.js 22.5+ and npm. Platform build tools are listed in
the setup guides. Portable Windows packages bundle the native host and Blindly4.

```sh
git clone --recurse-submodules https://github.com/aleski-green/sapiens4.git
cd sapiens4
codex login
./start.sh --open
```

On Windows, use `.\start.ps1 -Open`. The local UI opens at
http://127.0.0.1:4174/workspace/. Existing checkouts initialize dependencies with
`git submodule update --init --recursive`.

The UI uses PureScript/Halogen. Source startup builds it when needed; completed
packages need no Node installation. Third-party dependencies live in the pinned
[libs4](https://github.com/aleski-green/libs4) submodule.

The header switches between local corpora and saved remote connections. Selection
does not change execution: use Pause or Activate separately. On mobile, install
and open the Home Screen app before pairing, then approve the matching code on
the host. Each corpora supports one approved remote device.

## Documentation

Source is grouped by responsibility: `sapiens/` contains State, Work and Host;
`web/` contains shell, features and theme; `osspecific/` contains native
integration and packaging for macOS and Windows. `Build.hs` builds the application
using dependency manifests in `libs4`. Tests and their helpers live in `spec/`.

- [Usage, configuration, data and API](documentation/reference.md)
- [UI architecture](documentation/ui.md)
- [Running behavior tests](documentation/testing.md)
- [Contributing](CONTRIBUTING.md)

Windows support was contributed through the
[fatmahalqaisi-code/sapiens4 fork](https://github.com/fatmahalqaisi-code/sapiens4).

## License

Sapiens4 is source-available under the [Sustainable Use License 1.0](license/LICENSE.md).
See [licensing and commercial services](license/LICENSING.md).
Commercial inquiries: [license@sapiens4.ai](mailto:license@sapiens4.ai).

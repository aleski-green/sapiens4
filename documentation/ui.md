# UI architecture

The UI is PureScript/Halogen. Views render the model; typed actions handle user
input and external events. Halogen owns rendering and subscription cleanup.

| Source | Responsibility |
| --- | --- |
| `web/shell` | Model, actions, navigation, component lifecycle, shared HTML and build |
| `web/features` | Conversations, tasks, Memo, workspaces, dialogs and connections |
| `web/theme` | Styles and responsive layout |

Requests carry identities and a corpora epoch so late responses cannot replace
another selection or newer data. Send completion clears only the submitted draft
and attachments; newer input survives. Failed resources require explicit retry.
Native browser reports are serialized, and corpora switching restores that
corpora's cached preferences.

Browser/native APIs and third-party bindings live in
`libs4/purescript/src/Libs4/Browser.purs` and its foreign implementation.
Application behavior stays here. Host payloads are JSON; navigation, actions,
dialog kinds and resource lifecycles use algebraic types. Memo markup is rendered
through an allowlist, and native guest views have no app-control bridge.

Build with GHC, Cabal, Node.js 22.5+ and npm:

```sh
git submodule update --init --recursive
runghc Build.hs
```

The shell's `BuildUI.hs` helper compiles and bundles the UI. After the host has
been built, `.build/bin/sapiens4 build-ui` rebuilds only the UI.
The pinned toolchain emits `app.js`, `sw.js` and `guest.js` into `.build/web`.
Generated bundles are not committed. Source startup and packaging invoke the build;
completed packages need no compiler or npm. See [Testing](testing.md) for validation.

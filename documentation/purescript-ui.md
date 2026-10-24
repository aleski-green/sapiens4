# PureScript / Deku UI

The entire browser UI is implemented in PureScript on `haskelization-yolo`, with
Deku rendering. Python remains the host; Swift and WebView2 remain the native
shells during this UI-first phase. HTML, CSS, icons and manifests remain assets.

## Sources and delivery

The three web responsibilities remain `shell/`, `features/` and `theme/`.

- `shell/Startup.purs` boots the app; `Shell.purs`, `Session.purs` and `Panes.purs`
  own navigation, saved state, reconnect/scroll restoration and responsive layout.
- Feature modules own chat/composer, groups and work, notes and mentions, native
  workspace controls, corpora and pairing, relay settings, encrypted transport,
  QR capture and installation/trust persistence.
- `theme/Theme.purs` owns theme preferences and accessible controls.

`View.purs` mounts Deku Nuts and owns disposal. `Runtime.purs` provides shared
JSON/platform access and renders escaped dynamic templates as Deku nodes, keeping
DOM namespaces and boolean attributes intact. Task rows use Deku elements
explicitly. Transcript reconciliation retains unchanged keyed nodes, focus and
scroll position. `Interface.purs` exposes component entrypoints for embedded
browser hosts and observation helpers.

FFI JavaScript is limited to browser/platform primitives and a static SVG import.
Application decisions, templates and handlers are in PureScript. Host JSON and
opaque browser handles still use a shared dynamic boundary type; this is not yet
a full typed schema for every host response.

Generated JavaScript is checked in as the delivery format. The host serves the
compiled `application.js`; there is no legacy JavaScript UI fallback. The build
also emits the existing public remote and service-worker assets, plus component
and text entrypoints. Normal startup needs neither Node nor the compiler.

## Build

Dependencies, manifests, locks, compiler output and caches live in `libs4`.
Deku 0.12.2 is pinned by Git commit, with its compatible Hyrule/TLDR dependencies;
PureScript 0.15.16 and Spago 0.93.44 are pinned npm packages.

```sh
npm ci --prefix libs4
node web/shell/build.cjs
ruby libs4/ruby/bundle.rb exec rspec
```

Use Node 20.9+ and the Ruby/Python setup in `testing.md`. A release build compiles
into a fresh ignored directory and writes assets only after every bundle succeeds.
`--output-dir DIRECTORY` builds separately; RSpec verifies byte-for-byte agreement
with shipped assets. `--development` reuses an ignored compiler cache for editing.
The SVG in `shell/favicon.svg` supplies the browser and native icons. After changing
dependencies, regenerate notices with `node libs4/purescript/notices.cjs`.

## Coverage

All test expectations are evaluated by RSpec. JavaScript, Swift and C# helpers
perform browser/native operations and report observations; they do not decide
whether behavior passed.

`ui_contracts_spec.rb` retains 720 observations from the ten legacy JavaScript
contracts. Named case data in `spec/fixtures/browser/` preserves the original
expected values and patterns, including repeated scenarios. Large exact-text
comparisons use SHA-256 and length; regex checks inspect the complete text. DOM
identity observations retain the stable-node checks. The retired-mention check
uses the real rendered button instead of the previous formatter stub.

Separate RSpec contracts cover panes, tasks, themes, chat restoration/scrolling,
corpora, relay settings, trust storage, encryption, QR capture, service workers,
and reproducible builds. Native decision fixtures and WebKit observations are
asserted in `platform_spec.rb`; Windows rendering/theme observations are asserted
in `windows_package_spec.rb` when run on Windows. This preserves behavioral
contracts, not a claim of equal line/branch coverage across languages.

For native accessibility checks against isolated temporary hosts:

```sh
SAPIENS_TEST_BLINDLY4=/absolute/path/to/blindly4 ruby libs4/ruby/bundle.rb exec rspec spec/workspace_accessibility_spec.rb
```

These exercise fixture windows and temporary data, including the compiled theme
and pane controls. They do not start the user's installed app or call paid models.

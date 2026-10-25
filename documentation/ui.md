# PureScript / Halogen UI

The application UI is compiled PureScript using Halogen. `Sapiens.Main` mounts a
Halogen component; typed actions update its model through `HalogenM`. Rendering
produces `ComponentHTML`, with keyed conversations and framework event handlers.
There is no handwritten JavaScript application or parallel DOM rendering runtime.

## Responsibilities

| Collection | Responsibility |
| --- | --- |
| `web/shell` | Typed navigation, model, actions, component lifecycle, common HTML, effects and build entrypoints |
| `web/features` | Conversations, task history, Memo, native workspaces, dialogs, corpora and encrypted remote sessions |
| `web/theme` | Shared styles and responsive layout |

`Navigation` defines closed pane, activity, view, scope and period types. `Model`
owns drafts, attachments, navigation, documents, workspace state and dialog state.
`Action` describes user input and asynchronous results. `App` handles the shell,
with corpora and dialog evaluation in their respective feature modules. Views are
pure functions of the current model. Foreign handles and disposers live separately
in the connection runtime.

Host protocol payloads remain JSON at the boundary. Navigation, dialog kinds,
actions and resource lifecycles are algebraic types; this does not claim that every
host record has a checked PureScript schema. Task/Memo decoders validate their
required shapes before accepting a successful response.

## Asynchronous behavior

Documents use `RemoteData a`: NotAsked, Loading with an optional previous value,
Ready, or Failed. Each request carries its corpora epoch, sequence, resource key,
revision and path. A late response can update only its matching request and epoch.
Failures remain stable until explicit retry. A document can finish while another
view is selected without changing that view.

Send completion captures its owner, epoch, submitted text and attachments. It
clears only unchanged submitted text and sent attachments, preserving a newer
draft. Dialog results carry dialog identities. Native browser reports are queued
and serialized, and workspace revisions reject stale snapshots. Corpora changes
start a new epoch and restore preferences from that corpora's local cache.

Halogen manages rendering and subscriptions. Global event emitters return their
cleanup effects directly to Halogen; no separate listener registry is needed.
Input values and checkbox changes use Halogen's event decoders. The application
disposes remote clients and camera resources when unmounted. PureScript also
owns relay authentication, encrypted request routing, reconnect handling,
invitation validation, local persistence and service-worker cache policy.

Document, preview and image requests keep their continuations beside the request
inside `HalogenM` forks. Shared epoch guards reject responses from an earlier
corpora; document sequence and preview-path checks still distinguish overlapping
requests. These local completions do not need separate shell action constructors.
Reusable pure view functions supply text nodes and button behavior. Outbound JSON
uses Argonaut record encoding where the keys are fixed; dynamic dictionaries keep
their explicit keys. Host response validation remains at the boundary.

## Foreign interfaces

`libs4/purescript/src/Libs4/Browser.purs` declares the shared browser interface.
Its JavaScript foreign implementation supplies browser/native APIs, JSON I/O,
cryptographic library calls, DOM measurements, file selection and inert markup
parsing. It does not contain application navigation, dialog, rendering or protocol
logic. Third-party sources, package manifests, lockfiles, installed packages and
caches stay in libs4. License notices remain intact.

Memo markup is parsed inertly and rendered through PureScript's tag and attribute
allowlist. Authenticated images are loaded separately. Native guest WebViews keep
their origin and privilege isolation; their blank/text styling is compiled from
`Sapiens.Guest`. The native hosts retain only callback invocation strings for
crossing the WebView boundary. They do not embed UI JavaScript programs.

Browsers still execute generated JavaScript. Removing handwritten JavaScript
application source does not remove the compiler output or necessary foreign and
vendor code. Generated bundles live under `.build/web`, outside version control.

## Build and distribution

With Node.js 22.5+, npm and Python available:

```sh
git submodule update --init --recursive
python3 web/shell/build.py
```

The build installs the pinned PureScript compiler, Spago and esbuild from libs4,
compiles the application and emits `app.js`, `sw.js` and `guest.js`. A source
fingerprint skips unchanged builds. No compiler or npm installation is needed to
run a completed package. Source startup and platform packaging invoke this build;
the relay image uses a separate Node build stage.

## Verification and size

RSpec exercises public HTTP/process contracts and drives the shipped desktop UI
through Blindly4. Tests contain no JavaScript execution or private DOM assertions.
Coverage includes navigation, documents, late responses, retries, drafts, reading
position, Groups, corpora lifecycle, encrypted pairing and native browser tabs.
See [testing](testing.md) for platform requirements and remaining real-device gaps.

Measure source with `o200k_base`, counting each UTF-8 file independently and
including whitespace. Compare the prior UI JavaScript to the PureScript modules,
and report new shared foreign bindings separately and in the total. Exclude
compiler output and third-party source. Types, explicit effects and error handling
may increase source size even when duplicated rendering machinery is removed.

Compared with `d4ae491` using `o200k_base` (per UTF-8 source file, including
whitespace; generated bundles and third-party source excluded):

| Source | JavaScript | Initial migration (`f34056e`) | Refactored | Change vs JavaScript |
| --- | ---: | ---: | ---: | ---: |
| UI application source | 47,142 | 59,872 | 57,553 | +22.08% |
| UI plus new shared bindings | 47,142 | 64,175 | 61,856 | +31.21% |

The initial increase was 12,730 application tokens plus 4,303 shared binding
tokens. The migration introduced type declarations, imports, explicit effects and
rendering syntax while retaining manual JSON assembly and completion dispatch.
The abstraction pass removes 2,319 tokens (3.61%) from that combined total, while
also preserving the subsequently merged Windows scroll fix. Against its immediate
parent `179b141`, the reduction is 2,364 tokens (3.68%). Bindings remain in the
measurement, and no application code was moved into libs4 to obtain the reduction.

Source compression does not imply a smaller executable: esbuild reports the main
bundle at approximately 322.3 KiB versus 318.5 KiB for the initial migration.
Generic record encoding introduces compiled instances. Further component splits
should be justified by independent state, reuse or lifecycle ownership; slots,
inputs and outputs can add source instead of reducing it.

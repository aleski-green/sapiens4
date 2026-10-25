# UI model, views and effects

The workspace now has a single state writer: `dispatchUI`. Feature handlers send
messages to a pure `updateUI(model, action) -> [model, commands]`. The runtime
commits the returned model before interpreting commands. This is preparation for
an incremental PureScript/Halogen or Elm migration, with JavaScript still serving
as the current implementation language.

The boundary follows [Elm's model/update/commands architecture](https://guide.elm-lang.org/effects/)
and [Halogen's separation of rendering and effectful evaluation](https://purescript-halogen.github.io/purescript-halogen/guide/03-Performing-Effects.html).
No compiler or dependency pin changes in this step.

## Modules and ownership

| Module | Responsibility | Migration destination |
| --- | --- | --- |
| `shell/ui.js` | Navigation tree, valid activity states, pane transitions | Pure navigation types and functions |
| `shell/model.js` | Initial state, snapshot projection, roster, composer, document lifecycle | Model, Action/Msg, update, JSON decoders |
| `shell/view.js` | Task rows, task history and shared personal/group transcript as HTML values | Halogen `ComponentHTML` or Elm `Html Msg` |
| `shell/app.js` | Dispatch, command interpreter, mounting and input adapters | Runtime/effect interpreter, component wiring |
| `shell/bridge.js` | Snapshot polling, persistence, chat reconciliation and lifecycle | Subscriptions, effects, browser adapter |
| `features/*` | Feature presentation, scoped dialogs and platform adapters | Subsequent components or foreign adapters |

Workspace state contains the host snapshot, projected agents/messages, selection,
activity, panes, drafts, workspace tabs, document requests, disclosure state and
composer state. There is no second mutable `live` snapshot, task cache or send set.
Rendering no longer changes selection, roster scope or workspace state.

The model contains plain data. It does not contain elements, promises, callbacks,
network clients or native handles. Snapshot projection mutates only newly created
local arrays/records; previous models and incoming snapshots are not modified.
Clock and connectivity arrive as explicit input messages.

## Messages and effects

| Message family | Inputs and behavior |
| --- | --- |
| Select / Scope / Navigate / Filter / Search | Validate navigation, retain drafts, choose a roster and activity |
| Pane / Viewport / Home | Project pane visibility with desktop/phone limits and recency |
| Snapshot / Reset / Workspaces | Accept host state; Reset starts a new corpora epoch |
| Draft / Expand | Store composer text and disclosure state |
| Send / MessageSent / MessageFailed | Capture a submission, prevent duplicate sends, retain newer drafts on completion |
| Clarify / Uploading / Attachment | Compose clarification and attachments without direct model mutation |
| RetryDocument / DocumentReceived | Explicit retry and response acceptance by request identity |
| Connection / Clock | Inputs from runtime subscriptions |

Commands describe loading a document, sending a message, saving preferences,
notification and UI adapter work. `performUI` owns their effects. Command results
re-enter the model through messages. Unknown action/command tags throw;
JavaScript does **not** provide compile-time exhaustiveness or effect typing.
Some region-render commands remain transitional: a typed framework's renderer
will replace them, while focus, clipboard, persistence and native calls stay effects.

Navigation is validated by `activityState`: each panel admits its own views and
filters, Group-only Deleted cannot leak into personal tasks, and old Notes/Tasks
preferences decode to Work. The same navigation tree supplies labels and paths.

## Shared document lifecycle

Task history and Memo use one parameterized resource state, corresponding to:

```purescript
data RemoteData a
  = Loading Request (Maybe a)
  | Ready Request a
  | Failed Request String
```

This is a type sketch for the migration, not a compiled dependency. A request has
`kind`, owner, revision, corpora epoch and sequence. `currentDocument` projects the
required resource from the model; `loadDocument` emits a command only when its
revision changes or the person explicitly retries. Decoders check response data
before it can enter Ready.

A response can commit only to its current request and epoch. It can finish while
the person is elsewhere, but only the currently selected document is rendered.
No request retains a mount. This covers leaving and returning, changing views,
retries, newer revisions and switching corpora. Failure is stable until retry;
it does not cause an automatic request loop. Memo now has the same retry behavior
as task history.

Send completion also carries its captured epoch and owner. It removes only the
attachments sent and clears only the unchanged submitted text, preserving a new
draft typed while confirmation is pending.

## Views and adapters

Personal and Group transcripts share one projection. Warnings, author names,
attachments and progress are part of that value, replacing render-then-patch
passes over message nodes. Task/routine rows share a view function. Dynamic text
is escaped; rich chat text passes through the existing formatter explicitly.

DOM mounting and interaction are runtime responsibilities. Task mounts retain
focus/disclosures when their data has not changed. Chat retains its keyed
reconciliation and reading-position adapter, including the iOS foreground handling.
Memo sanitization, image loading, native browser geometry, file previews, file
selection and clipboard access remain browser/platform adapters. Their safety
boundaries and the native guest-webview isolation are retained.

## Migration readiness

The workspace core is ready for a **staged migration**, starting with task/Memo
state and the composer. The whole frontend is not yet a typed Halogen/Elm program.

1. Translate the model records and closed message/resource variants; add checked
   decoders for the complete host snapshot. Preserve request epochs and sequences.
2. Replace task/transcript HTML projections with typed HTML and native framework
   event handlers. Run the same accessibility scenarios during the replacement.
3. Interpret commands using Halogen effects/FFI or Elm commands/ports. Replace
   polling and browser lifecycle listeners with managed subscriptions.
4. Migrate the remaining settings, navigation menus and connection dialogs as
   components. Keep transport/crypto, sanitized rich Memo and native guest views
   behind explicit foreign adapters until they have separate migration coverage.

Do not build a second virtual-DOM framework or simulate a type system in JavaScript
just to imitate syntax. The useful preparation is explicit data ownership, pure
transitions/projections and named effect boundaries. Type safety and framework
lifecycle management come with the actual migration.

## Behavior and size checks

RSpec drives the shipped app through Blindly4 and the real service. It does not
import these functions, execute test JavaScript or assert DOM details. Coverage
includes navigation, saved history, retry, late task/Memo responses, corpora
switching, unsent drafts, a new draft during send confirmation, reading position,
Group isolation, remote reconnection and native workspaces. See
[testing](testing.md) for real-device gaps and commands.

Compare exact source snapshots with `o200k_base`, summing tokens per UTF-8 file,
including comments and whitespace. Report owned UI JavaScript separately from all
owned code plus tests; exclude dependencies and generated/binary files. Also
report physical lines. Moving functions between files must not count as savings.
Migration preparation can trade removed duplication for an explicit model, so a
large compression percentage should not be assumed from architecture alone.

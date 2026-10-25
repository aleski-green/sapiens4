# UI state, views and effects

The UI stays plain JavaScript with no new build step. Its shared decision core is
`web/shell/ui.js`; DOM integration stays in `shell/app.js` and the feature files.
This follows the Model–Update–View separation described by
[Elm](https://guide.elm-lang.org/architecture/) and the state/action/render
boundaries described by [Halogen](https://purescript-halogen.github.io/purescript-halogen/guide/02-Introducing-Components.html).

## State transitions

`updateUI(model, action)` is pure and returns `[nextModel, commands]`.
`dispatchUI` commits the model before interpreting commands that render, focus,
scroll or save. DOM listeners supply explicit actions:

| Action | Payload | Transition |
| --- | --- | --- |
| Select | id, draft | Save the outgoing draft, select a Sapi/Group, open its conversation |
| Scope | scope, draft | Select Chief and show the requested roster |
| Navigate | panel, view, period | Enter a valid activity state |
| Filter | period | Change the active view's history filter |
| Search | value | Filter the roster |

Navigation has one `panel/view/period` value, replacing independent globals for
each panel's last view and task/routine filters. `activityState` validates saved
and incoming values, maps legacy Notes/Tasks panels to Work, and restricts filters
to their view and owner. The navigation tree supplies labels, paths and valid
Work views. `defaultWorkActivity` chooses the initial Work view from existing
tasks and routines; ordinary refreshes preserve manual navigation.

`paneState` is a separate pure transition/projection for visibility and recency.
The shell supplies viewport capacity and tab availability. It retains desktop
workspace intent while limiting phones to one or two useful panes.

## Views

`element(tag, className, textOrChildren, attributes)` composes task and Memo DOM.
Strings become literal text, arrays become children, and function-valued `on*`
attributes become event listeners. Attribute objects are trusted view definitions,
not arbitrary API payloads. Rich content still goes through the existing text
formatter or Memo sanitizer explicitly.

Keep stable DOM when a view has not changed. Chat's existing keyed reconciliation,
scroll anchoring, focus handling and native browser isolation remain in place.
CSS uses shared `:is(...)` selector prefixes only for alternatives with equal
specificity; declarations and cascade order remain intact. SCSS is unnecessary
for this change and would add a dependency/build step.

## Effects and limits

Task documents have `loading`, `ready` or `failed` states. Validate response fields
before constructing a ready state. A pending cache entry is also its request
identity: only the current entry can commit a result. It tracks the current mount
so leaving and returning during loading still receives the result. Switching
corpora clears task caches and expansion/clarification state; old requests cannot
commit into the new corpora. Failure offers an explicit retry.

View and period persist in device preferences; the host preferences API keeps its
existing schema. No server protocol or dependency pins change.

This is an incremental JavaScript architecture, not PureScript's compile-time
exhaustiveness or effect typing. Network/native adapters and some older feature
handlers remain imperative. Extend the action/update boundary for new navigation
behavior; keep I/O outside pure transitions and decode data at its boundary.

RSpec remains the test entrypoint. `spec/ui_state_spec.rb` exercises the shipped
workspace through DOM actions and controlled HTTP responses, including restored
views, invalid preferences, remounting, cross-corpora races and retry. Existing
browser, service and native contracts remain required.

Measure compression as `loct_max = max(17 * code_lines, o200k_base_tokens)` on
owned source, excluding dependency submodules and generated files. Count both
production UI and the source total including regression tests, so moving code or
adding tests cannot conceal growth. Report physical lines as a conservative
alternative alongside code lines excluding comments and blanks.

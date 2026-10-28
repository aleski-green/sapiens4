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

Application responsibilities are behavior (`sapiens/`), presentation (`web/`),
and native integration (the platform-specific `macos/` and `windows/` collections).
Keep native source with its platform's launcher, resources and packaging. The two
platform roots are a required platform split, not an artificial third platform.
There is no application source directory named after its implementation language.

The backend has three responsibility groups:

- `sapiens/State/`: domain values, shared state/file primitives, persistence,
  population, Notes, workspace records and group models.
- `sapiens/Work/`: model and computer execution, delegation, group conversations
  and work, and scheduled routines. `Schedule/` contains the command parser,
  response codec and standalone command entrypoint together.
- `sapiens/Host/`: service lifecycle, management, HTTP/assets and remote access.
  `Remote/` is a cohesive collection of pairing, transport and relay modules.

State must not import Work or Host. Work consumes State and must not import Host
or native desktop implementations. Host composes both; remote registration may
call the service, while the service remains independent of remote transports.
Native shells share the pure `State.Domain` codecs. These are dependency
boundaries, not a requirement to split every module into three files.

Web responsibilities remain `shell/`, `features/`, and `theme/`; shell divides
model, interaction and rendering, with entrypoints/assets as leaves. Its UI build
helper lives with the shell. Root `Build.hs` orchestrates application builds.
Test helpers live directly in `spec/support/`, regardless of their language.
Prompts, tests, documentation and licenses are cohesive collections. External
`libs4` and `blindly4` repositories retain their own layout; language-specific
dependency manifests and caches are tool-owned, not application divisions.

Review changes against these boundaries; tests exercise public behavior rather
than asserting the names, shape, or import graph of private implementation code.
Persistent `agentpy/` data paths remain unchanged by source reorganization.

## Third-party dependencies

Keep dependency manifests, lockfiles, vendored libraries, package caches and
installed test dependencies in the `libs4` submodule. Sapiens4 owns application
and test source, with explicit imports into libs4. Do not add a root Gemfile,
package manifest, requirements file, or checked-in third-party build output.
Update dependencies in libs4 first, then advance its submodule pin here.

## Hardcoded model prompts

All hardcoded model prompts must live in the repository's root `prompts/`
directory as separate, descriptively named `.md` files, such as
`prompts/conversation.md` and `prompts/computer-use.md`.

Application code must load these files instead of embedding prompt text in source
code. This includes system instructions, prompt prefixes/suffixes, reference
wrappers. Dynamic values may be inserted using
template placeholders; user messages, Notes contents, and generated state are data,
not hardcoded prompts.

## Tests: RSpec and observable behavior

All automated test cases must be defined and run in **RSpec**, under `spec/`.
Do not add Python tests, a Python test runner, or a Python bridge that exposes
private application objects to Ruby. See [Testing](documentation/testing.md) for
setup, platform requirements and coverage limits.

Exercise real service, relay, build, and desktop entrypoints. Assert
HTTP responses, process output and exit codes, user-visible files, persistence,
permissions, and recovery. Control the environment at external boundaries:
model executables, network peers, and saved installation fixtures.
Never contact a paid model or use the developer's live installation in tests.

The purpose of using Ruby is to make implementation-coupled testing harder and
keep product behavior explicit. Testing Python with Python is not inherently
wrong; mocking internal classes, inspecting private state, and duplicating the
implementation produce the coupling we are avoiding. A different test language
does not make weak assertions meaningful.

Name each independent behavior as an RSpec example. Use named case tables for
validation variants and shared fixtures for setup. Combine steps when they form
one contract, such as submit → fail → retry → restart; do not hide unrelated
failures in a giant scenario. Keep all new behavior assertions in RSpec.
JavaScript and native programs may supply browser/platform probes that Ruby
cannot execute directly. Existing probes are invoked and checked by RSpec;
do not create another independently run test suite.

Run `ruby libs4/ruby/bundle.rb exec rspec` locally before submitting. Run platform cases on their
matching operating systems; scheduling cases use real minute pulses and belong in the full run.
Do not delete a behavioral guarantee merely because a private-method test is
being removed: replace its observable contract or document the precise gap.


## Contribution licensing

Read [LICENSE.md](license/LICENSE.md) and expressly accept the
[Contributor License Agreement](license/CONTRIBUTOR_LICENSE_AGREEMENT.md) before your
contribution is merged. Identify the pull request or commit range and the
agreement revision in your acceptance. Disclose third-party material and obtain
any required employer or other rights-holder authorization.

Maintainers must verify and retain the acceptance record for every contributing
rights holder before merging. This is a manual merge requirement; no automated
CLA service is configured. Earlier contributions need separate clearance.

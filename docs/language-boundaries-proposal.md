# Sapiens4: a small typed core with explicit environments

Status: proposed architecture, open for discussion. This specifies the target architecture and migration acceptance criteria; implementation proceeds through separate reviewed changes.

## 1. Objective

Minimize the maintained implementation and the number of concepts needed to understand Sapiens and Corpora. Keep their semantics in one small, typed Haskell core. Give the server, UI, operating system, integrations, and extensions clear boundaries around it.

Optimize for readable definitions, a single implementation of each rule, small policy diffs, and a limited amount of context for a human or coding agent to inspect. Count supporting protocols, wrappers, duplicated representations, and handwritten glue when evaluating whether a change reduces complexity. Moving code between repositories is useful organization, but does not by itself reduce the implementation.

## 2. Language ownership

| Component | Language | Responsibility |
| --- | --- | --- |
| Core: Sapiens and Corpora | Haskell | Domain types, state transitions, cognitive workflow definitions, permissions, admission, scheduling rules, budgets, memory commits, and coordination |
| Server | TypeScript | Local API, persistence, clock/timer infrastructure, Codex execution, Python execution, service adapters, streams, supervision, and recovery mechanics |
| Third-party plugins | Python | Externally supplied extensions, invoked through the server's extension contract |
| Sapi-owned kit | Python executable code, with instruction/manifest data | Skills, scripts, tools, and jobs a Sapi creates and improves to automate its own work and reduce future model usage |
| macOS | Swift | Native application, WebKit shell, Blindly4, OS capabilities, packaging, and native update operations |
| CORPORA UI | HTML, CSS, plain JavaScript | Presentation, forms, interaction, and explicit UI preferences |

TypeScript is the application server, including built-in external service adapters. There is no Haskell application host responsible for subprocesses or SQLite, and no built-in Python agent/model runtime in the target design.

## 3. Two definitions that govern the design

### Who calls Codex?

The TypeScript server invokes `codex exec` with the prepared prompt using a subprocess argument vector or supported input stream. Prompt text is never interpolated into a shell command. The server supervises that process, reads its output and usage, and reports outcomes through the core.

Haskell determines whether the run is allowed, its role in the workflow, the permitted capabilities and limits, and how its result changes state. Python is not the built-in Codex runner. Swift does not run agent reasoning.

### What is the agentic kit?

The kit is the reusable automation that each Sapi builds for itself. It is not the name for Codex's own built-in skills or tools.

- A **skill** describes reusable know-how and how to apply one or more executable tools. Its instructions and manifest are data; executable components are Python.
- A **script** is a concrete Python program for a computation or procedure.
- A **tool** exposes a reusable operation with a defined input and result contract, backed by Python code.
- A **job** binds reusable executable work to an input, trigger, or recurring purpose. Its work implementation is Python; its registered schedule and execution records are core domain state.

These are views of a small shared package model, not four independently implemented extension frameworks. One script can implement a tool used by several skills and jobs.

A **plugin** is an externally authored package installed to extend the system. A **Sapi-owned kit package** is authored and maintained by a Sapi for its own work. They can use the same execution protocol while preserving different provenance, ownership, and update authority.

Codex's native skill/tool mechanisms may be used to expose access to the server or kit. Such integration is an execution detail and does not redefine the kit.

## 4. The Haskell core

The core has three cohesive areas: `Sapiens`, `Corpora`, and the shared protocol. They belong to one core, with no duplicated rules in the server or Python workers.

### Sapiens

Owns individual agent identity and lifecycle; task and execution transitions; recurring definitions and missed-occurrence rules; budget admission and settlement; strategy readiness; observation baselines and wake policy; memory revisions and accepted patches; kit registration, activation, and version references; and conditions for accepting completion.

Owns built-in cognitive workflow structure: for example, when a result requires review or a memory proposal requires criticism. Prompt content can live in versioned Markdown assets. The model performs inference through calls executed by the TypeScript server. No Python reasoning runtime is required.

### Corpora

Owns membership, the main orchestrator, hierarchy invariants, authority, delegation, assignment, inter-agent message semantics, shared resources, team review requirements, and escalation. It supplies the authoritative relationships and visibility rules used by UI queries.

### Pure decisions

A small conceptual interface is:

```haskell
decide :: DecisionInput -> Either Rejection Decision
```

`DecisionInput` contains the current versioned state, an authenticated principal supplied by the server, a command, explicit time, and required observations. `Decision` contains the resulting state changes, events, receipt, and requested effects.

Time, generated identifiers, and environment observations are explicit inputs. The same input produces the same decision. A minimal executable wrapper can expose the core over versioned local IPC without giving it database, network, or process ownership.

Use direct domain types and ordinary functions. Add abstraction when it removes demonstrated duplication. Keep provider payloads, database rows, file paths, HTTP frameworks, and OS objects outside the pure domain.

## 5. The TypeScript server

The server is the application's running host. It:

1. Serves the UI and exposes the local API.
2. Authenticates callers and supplies their identity to the core.
3. Reads authoritative state and asks the core to evaluate commands.
4. Atomically stores accepted state changes, receipts, events, and pending effects.
5. Runs the timer infrastructure and submits time observations to the core.
6. Dispatches effects after their transaction commits.
7. Invokes Codex and supervises model executions.
8. Starts Python scripts and plugin workers when requested by an accepted effect.
9. Handles built-in service integrations, authentication, pagination, and transport.
10. Routes macOS effects to Swift and Blindly4.
11. Stores artifacts and attachments and provides controlled access to their contents.
12. Streams progress, exposes projections, and records diagnostics.
13. Performs restart recovery, backups, migrations, and graceful draining.

The core owns the meaning of state. The server owns storage and execution mechanics. The server must not independently decide that a task may run, a budget may be exceeded, an uncertain action may be retried, or a memory patch is acceptable.

Low-level implementation choices such as SQL statements, stream parsing, and safe transport retries belong in the server. Behavior that changes domain outcomes belongs in the core.

## 6. Commands, persistence, and effects

Use one versioned command/event/effect contract. Domain and wire types are defined in the core, with mechanical schemas/client types exported for other components and shared fixtures stored in `contracts/`. Avoid maintaining separate handwritten domain models in each language.

For the first implementation, use one serialized mutation path and a Corpora revision. Introduce finer-grained concurrency only if measured demand justifies its extra rules.

For each mutation, the server:

1. Authenticates the caller and validates the wire envelope.
2. Checks whether the same command has a saved receipt. Identical retries return that receipt; conflicting reuse of an ID is rejected.
3. Loads the current state and revision in the serialized transaction path.
4. Sends the command and state to the Haskell evaluator.
5. Stores an accepted decision's state changes, receipt, events, and effect outbox entries in one SQLite transaction. A rejection can also have a durable receipt without changing domain state.
6. Dispatches effects only after commit.

The evaluator performs no external actions. If evaluation or commit fails, no effect from that attempted transaction runs.

Effects have stable IDs and explicit attempt IDs. Results are commands correlated to those IDs. The core validates the current attempt and revision before accepting them.

Delivery is recoverable and may be repeated. An idempotency key does not make an arbitrary external operation exactly-once. If a worker disappears after a possible action, record an unknown outcome and reconcile before retry when required.

Separate three facts: a process exited; its execution produced a result; the task's requested objective was accepted as complete.

## 7. Sapi-owned automation lifecycle

A Sapi can improve its own efficiency through this sequence:

1. A Codex run identifies repeated work that can be automated.
2. The Sapi authors a Python script/tool and its manifest, with representative tests and expected results.
3. The server stores an immutable candidate version and runs validation in the configured extension environment.
4. Validation results and a registration request enter the core.
5. The core accepts or rejects activation and records the owner, version, allowed capabilities, and relevant job bindings.
6. The server can invoke that pinned version directly for subsequent admitted work.
7. A new Codex call occurs when the core admits a reasoning request, including when a kit result reports that reasoning or repair is needed.
8. Improvements create a new version. Existing executions retain their original version reference; rollback changes future executions to an earlier accepted version.

Kit manifests record an owner, version/content reference, entry point, input and result schema references, requested capabilities, resource requirements, and validation evidence. Job records add schedule/trigger information and saved inputs. Keep one common envelope and allow operation-specific payloads within it.

The server launches the Python interpreter directly for Python work. A Python result can include artifacts, observations, proposed checkpoints, requested effects, or a request for reasoning. Result statuses are explicit: for example `NoChange`, `Changed`, `NeedsReasoning`, `Failed`, or `OutcomeUnknown`.

The core decides how each result affects durable state. Successful process exit alone does not advance a watcher baseline or mark a task complete.

## 8. Example: a Sapi reduces its own token usage

An agent initially uses Codex to design a Python job that reads a bounded source, extracts relevant changes, and computes a compact summary.

At a later interval:

```text
TypeScript timer submits the current time
    -> Haskell admits the due job and requests RunPython
    -> TypeScript runs the pinned Sapi-owned Python job
    -> Python returns an observation and proposed checkpoint
    -> TypeScript submits that result to Haskell
    -> Haskell accepts the checkpoint or requests follow-up work
```

If the observation satisfies the job's configured completion conditions without reasoning, the interval ends with no model invocation. If interpretation is required, Haskell can request `RunCodex`, and TypeScript invokes Codex with the compact observation.

Measure model calls, token usage, task quality, and job failures across repeated runs. Generating a script is useful only if its reuse produces the intended result more efficiently.

## 9. Plugins and capability boundaries

Plugins use the same invocation, artifact, result, and requested-effect machinery as kit packages. Their publisher and installation authority replace the kit's Sapi authorship and update authority. External service integrations supplied by a third party can therefore be Python plugins; built-in service adapters belong to the TypeScript server.

Extensions receive scoped inputs and working directories. They do not receive direct access to the host database or authority to grant themselves capabilities. Core mutations always enter through authenticated commands. Capability requests can be made during execution through the server.

The server and platform layer must enforce the intended filesystem, credential, network, and process boundaries. A separate process running unrestricted as the same OS user is not sufficient proof of isolation. Any strong confinement claim requires an implemented and tested platform mechanism.

An extension request for model reasoning returns to the server and core admission path; the supported kit API does not expose an alternate unrestricted Codex runner.

## 10. UI and macOS

The UI remains HTML, CSS, and plain JavaScript. It renders state, offers controls, keeps explicit presentation preferences, and consumes the server's versioned API. It has a small JavaScript client and shared fixtures. Client-side validation improves interaction; it does not replace core decisions.

Swift owns the macOS window, WebKit integration, menus, Dock identity, native notifications, file selection, credential-store access, accessibility, desktop input, and packaging. Blindly4 remains the native observation/action component.

The Swift shell launches or reconnects to the TypeScript server. Native update operations coordinate with server draining and state migration. Recurring work continues according to server lifecycle policy, independently of whether a UI window is visible.

## 11. Repository and data boundaries

```text
sapiens4/                  application assembly and TypeScript server
  server/                  API, persistence, execution, model/service adapters
  contracts/               exported schemas, protocol fixtures, compatibility tests
  integration-tests/       end-to-end and crash/recovery checks

sapiens-core/              Haskell package and minimal evaluator executable
  Sapiens/                 individual agent semantics
  Corpora/                 collective semantics
  Protocol/                commands, events, effects, receipts

lab-corpora-ui/            HTML/CSS/plain JavaScript
sapiens-macos/             Swift shell and native application integration
blindly4/                  Swift computer capabilities

plugins/                   installed third-party Python packages
kit/<sapi-id>/             Sapi-authored instruction assets and Python packages
```

The last two locations describe runtime extension storage, not mandatory new Git repositories. Their package contents can be versioned or published independently when useful. Stable component boundaries can be introduced in the existing checkout before repositories are physically separated.

SQLite stores authoritative domain state, receipts, events, and the effect outbox through the TypeScript server. UI projections can be rebuilt from authoritative records; UI-only preferences have an explicitly UI-owned store. Immutable files hold large artifacts, memory content where appropriate, and kit/plugin versions, referenced by stable IDs and hashes.

Accepted memory and behavior references belong to the core. Search indexes and caches are derived data. There is no Python-owned authoritative Sapiens state in the target architecture.

## 12. Migration

1. Record current behavior and write the contract, state invariants, and expected differences. Identify authority for every existing record.
2. Add a pure Haskell task/execution/admission model and compare it against recorded behavior. Make budget reservation timing explicit; current task enqueue and later execution admission are separate operations.
3. Add the TypeScript command/persistence path and a fake effect executor. Prove atomic receipts, deduplication, and crash recovery without real external actions.
4. Add TypeScript-owned Codex execution and Python extension execution. Demonstrate one Sapi-generated reusable job and an unchanged interval with no Codex call.
5. Migrate one complete state slice at a time. Task state, related executions, and their budget obligations must have coherent ownership. Avoid two active writers for the same domain records.
6. Back up and import the old Python host/AgentPy data, including memory, relationships, schedules, tasks, budget obligations, artifact references, and history. Verify counts, IDs, references, and restart behavior before activation.
7. Move UI and Swift integration to the TypeScript server. Preserve the versioned contract and platform behavior.
8. Remove overlapping Python scheduling, persistence, budget, recovery, orchestration, and model-runner paths. Retain Python only for kit code and plugins.

Any legacy Python compatibility path is temporary and has an explicit removal gate. Rollback must account for effects produced after cutover; restoring an older database cannot undo actions already performed in the environment.

## 13. Acceptance criteria

- The same core input produces the same decision.
- One tested implementation owns each domain rule.
- TypeScript is the component that launches Codex and supervises it.
- Python is used for Sapi-owned executable kit components and third-party plugins.
- The built-in runtime operates without Python when no Python extension is used.
- UI source is plain JavaScript, HTML, and CSS.
- Duplicate commands preserve receipts and do not create duplicate effect intents.
- Crash tests cover pre-commit, post-commit, worker-start, result delivery, and uncertain external outcomes.
- Budget reservations, execution state, and accepted state changes remain consistent across restart.
- A saved Python job can complete repeated useful work without a model call; escalation remains available when needed.
- Memory proposals and kit updates cannot replace a newer accepted revision accidentally.
- Native capabilities and extensions cannot bypass the claimed authority boundaries in the supported execution configuration.
- Migration preserves ownership, identifiers, obligations, and artifact references.
- Handwritten code, duplicated rules, dependency burden, and files needed to understand representative changes are measured before and after each slice.

For policy changes, PRs identify the affected invariant and include a meaningful failing-before/passing-after case. Tests and module boundaries should make the rule visible without requiring a reviewer to trace every language in the application.

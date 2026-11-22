# Pulse storage (v00.02.00)

The host's domain store is `state.lmdb`. Agent state, settings, attachments metadata,
turns, routines, groups, work, archives, preferences and remote request receipts all
use this store. Each existing corpora data root owns one LMDB environment; atomic
transactions stay within that root. The relay server has its own SQLite database; device credentials,
installation selection, workspace files and media remain outside the domain store.

One process-wide clock fires every 500 ms (120 BPM), shared by local corpora. Each
corpora has an independently durable, monotonically increasing Pulse sequence.
There are no 60 BPM or hourly domain clocks. Routines use their saved `nextDue`;
voice and telemetry workers receive ticks from the same clock and use due times.
Pausing a corpora stops work admission, while its storage Pulse continues accepting
settings and commands. A delayed tick skips missed wall-clock beats without
launching catch-up work. Shutdown drains the final commands through the same commit
path. Initialization and explicit offline build migrations are commit exceptions.

## Command and commit boundary

The host queues commands in arrival order (bounded to 1,024 pending commands).
Each command runs intact against the preceding accepted state. A rejected command
restores its full tentative state, pending effects and transient run bookkeeping.
Netting compares the committed state with the final accepted state; it never removes
operations from inside a transaction. A change followed by its inverse produces no
field fact. Distinct events and messages retain their separate application records.

One LMDB transaction commits field facts, collection membership, text postings,
transaction receipts, intents and current projections. Successful callers are
released only after that transaction commits. A failed commit restores the in-memory
view and fails the affected tickets. Queued writes and PureScript buffers are not
durable. Closing a failed store discards pending work instead of committing it.

Provider actions capture their inputs at invocation and launch after commit. A
Vienna → invoke → Dubai sequence executes the captured Vienna input and leaves
Dubai as current state. Restart marks unfinished provider intents and running work
as interrupted; it does not replay potentially completed external effects. Remote
request results and domain changes share a commit, making redelivery idempotent.
Encryption then runs outside the Pulse; its envelope is committed before delivery,
so retries return identical encrypted bytes.
Legacy receipts without a recoverable plaintext response prevent re-execution and
report an uncertain outcome.

## Records and reads

The adapter preserves existing domain IDs and JSON API shapes. JSON objects and
arrays are decomposed into primitive leaf facts plus container markers, preserving
empty containers and array order. Pulse suffixes are unsigned 64-bit big-endian.
Paths use escaped JSON field names; a NUL separator distinguishes a logical path
from its Pulse suffix. LMDB key-size limits are checked before committing.

* `h/`: immutable field versions, tombstones and actor/transaction metadata.
* `i/`: immutable collection membership versions.
* `t/`: immutable trigram postings referencing a field and Pulse.
* `p/`: immutable commit receipts, including accepted net-zero transactions.
* `c/` and `meta/`: mutable current projections and the last committed Pulse.

Authoritative rows use LMDB's no-overwrite operation. History is never pruned.
Current projections are caches; startup loads current records without scanning all
history. `history`, `atPulse`, `fieldsAt`, and `members` resolve historical reads.
Substring search intersects trigram postings and verifies the actual text; current
search also checks that the matching version is still current. Short patterns use
a bounded history-prefix scan. Semantic indexing is outside this storage adapter.

The existing client protocol receives a revision notification after commit and
fetches a pinned committed snapshot. Reads cannot expose intermediate command
values that are netted away later in the same Pulse. This release retains that recovery mechanism rather
than introducing the proposal's separate field-delta wire protocol. App records are
adapted to primitive history without renaming existing Sapi, turn or routine IDs.

## Upgrades

See [the migration runner](../migrations/README.md). The baseline is `v00.01.00`,
and this build is `v00.02.00`. Normal startup checks the build marker and never
selects migrations by a schema number. Only the build script interprets legacy
formats. Original SQLite and JSON files remain untouched as historical input;
the new app never falls back to them as an alternative source of truth.

The desktop flow is check → download approval → verified staged payload → update
approval → close admission and stop work → stop host → verified Data/Config backup
→ sequential build scripts → candidate validation → activate the candidate.
The existing update coordinator restores both data and the previous executable on
candidate failure. Cross-build compatibility is provided by the candidate invoking
its bundled migration runner before opening its host.

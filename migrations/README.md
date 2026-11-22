# Build migrations

The legacy baseline is **v00.01.00**. The application and data target is **v00.02.00**.

`Main.hs` declares the ordered build transitions. `V00_02_00.hs` owns the complete
SQLite/JSON-to-LMDB transition, including old agent states, archives, preferences,
routines and retained historical rows. Schema interpretation belongs inside this
script; it is never used to select migrations. Ordinary startup only validates
`data-build.json` against the app build.

The desktop updater stops writers and verifies a Data/Config backup before the
candidate invokes `sapiens-migrate`. All registered child corpora are migrated.
The build marker is published only after each script completes and reopens its
output successfully. Failure before candidate selection restores the updater's
backup and old executable. Source launches against legacy roots refuse to open;
use the explicit migration executable after stopping writers and backing up both
Data and Config.

Future builds append transitions here (including explicit no-op transitions when
necessary). Packages retain intermediate scripts so users can skip releases.
Scripts run offline, outside the normal 120 BPM Pulse. They must never launch
providers or replay external effects. Routine occurrence IDs and due times remain
unchanged; the legacy multi-frequency counters are retained as historical data.

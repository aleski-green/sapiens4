# Tests

Use Lean from `spec/lean-toolchain`, Node.js 22+, curl, Chrome/Chromium/Edge,
and the platform build tools. `SAPIENS_TEST_BROWSER` selects the browser executable.
Tests use temporary data and a local model fixture.

Test cases and assertions live in Lean, including browser crypto vectors and
tamper rejection. JavaScript only bridges browser operations and returns observations.
Desktop jobs initialize a temporary workspace before launch; they do not cover onboarding.
If a browser exits during fixture startup, set `SAPIENS_TEST_BROWSER` to a working
Chrome/Chromium/Edge executable (Chrome was used for Windows qualification).

```sh
runghc build/Build.hs
./submodules/blindly4/macos/build.sh
lake -d spec test
```

`lake -d spec test -- headless`: service/relay jobs.
`lake -d spec test -- desktop`: native UI jobs; requires an unlocked desktop and
Accessibility permission. Run desktop tests serially.
`SAPIENS_TEST_BLINDLY4` selects the driver; `SAPIENS_TEST_MACOS_APP` selects a signed app bundle.

Linux: build with `--desktop`, then `sh environments/linux/qualify.sh NEW_REPORT_DIRECTORY`.
Windows: build the host and driver using their platform guides.

Coverage excludes installer lifecycle, native guest isolation, remote-client
UI, altered/expired encrypted delivery, load, native onboarding, provider
discovery, model-settings UI, full provider combinations, and Group scenarios.

Storage qualification is included in the headless suite. The native fixture
`spec/storage/Main.hs` exercises real LMDB transactions (netting, rollback,
post-commit effects, historical membership/search, failed commits, killed-writer recovery, shutdown and
shared-clock behavior). The Lean recovery jobs create a real legacy SQLite/JSON
root, reject implicit migration, run the explicit build migration twice, and verify
saved work and untouched source data through the running host API.

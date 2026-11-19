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
`lake -d spec test -- browser`: browser bindings, crypto and remote-device jobs; requires a visible browser and the accessibility driver.
`lake -d spec test -- desktop`: native UI jobs; requires an unlocked desktop and
Accessibility permission. Run desktop tests serially.
`SAPIENS_TEST_BLINDLY4` selects the driver; `SAPIENS_TEST_MACOS_APP` selects a signed app bundle.

Linux: build with `--desktop`, then `sh environments/linux/qualify.sh NEW_REPORT_DIRECTORY`.
Windows: build the host and driver using their platform guides.
Linux browser fixtures use guarded ASCII keyboard input with JSON Unicode escapes;
the browser receives the original Unicode payload. Readonly results are read by
accessible name because AT-SPI can expose them without an editable-text role.
Onboarding controls use keyboard activation on Linux after verifying the focused
control's PID, role and accessible name; consent and submission assertions remain unchanged.

Coverage excludes installer lifecycle, native guest isolation, remote-client
UI, altered/expired encrypted delivery, load, native onboarding, provider
discovery, model-settings UI, full provider combinations, and Group scenarios.

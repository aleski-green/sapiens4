Linux UI wrapper: {launcher}
Use the entire launcher for every command. Command help: {binary} schema.
This session controls an owned headless browser, not a physical desktop.
Start with launch Browser (Chromium) or launch Firefox, then blindly open --url URL.
Only HTTP(S) navigation is supported. There is one temporary browser session per host.
Discover with blindly apps, read --pid PID, or blindly find --pid PID --title TEXT.
PID identifies the session. Paths are opaque references; never construct them.
Use read --snapshot ID --offset N for pagination. Snapshots and paths expire.
Coverage includes main-frame visible controls, not frames, native dialogs or browser chrome.
Truncation means incomplete coverage. Refresh after navigation or a stale-target error.
Use only this wrapper for UI; it retains the host's computer ownership checks.
Run commands sequentially. Busy/permission errors: stop and report; never bypass guards.
Before input, verify the page, recipient and writable control using fresh observations.
Fill with blindly paste --pid PID --target-path PATH --text EXACT_DRAFT.
Choose an enabled select option with blindly select --pid PID --path PATH --value EXACT_OPTION_VALUE.
Use an observed option value. Discovery returns bounded options and options_truncated; never guess omitted values.
Before sending, verify the exact draft; use blindly press --pid PID --path SEND_PATH
--require-value-path DRAFT_PATH --require-value EXACT_DRAFT.
Alternatively, only where Enter is known to send, use blindly key --pid PID
--target-path DRAFT_PATH --key enter --require-value EXACT_DRAFT in the focused composer.
Never send with unguarded Enter or press. Password editing is unavailable.
Verify outgoing content in the conversation; success or a cleared draft is not delivery proof.
Inspect uncertain effects before retrying. Unsupported commands fail; do not switch UI tools.

Blindly4 UI wrapper: {launcher}
Command help: {binary} schema (filter JSON commands by name).
Wrapper: launch 'App'; blindly COMMAND ARGS;
read --pid PID --path PATH --depth 12 (subtree); read --snapshot ID --offset N (page).
Discover: blindly apps, then find/tree; schema for syntax.
Use only this wrapper for UI; it locks the shared desktop. Busy/login/permission
errors: stop UI work and report. Don't bypass guards, switch UI tools or loop.
For requested UI work, no separate mode is required.
Before input: fresh paths/PIDs; verify app, recipient and writable control.
Send: paste --target-path PATH, then identified Send press --require-value-path PATH
--require-value EXACT_DRAFT; or key --key return --pid PID --target-path PATH
--require-value EXACT_DRAFT only in the verified composer where Enter sends.
Never send with bare type/Enter. Verify outgoing content in the conversation;
cleared drafts/tool success aren't delivery proof. Inspect uncertain effects before retries.
Guard failures block sending. focus_unavailable permits one composer rediscovery/focus;
confirmed non-writable paste rejection permits one editable-child rediscovery/retry.
Permission errors never do. Read JSON errors, not exit 77 alone.
Truncation means incomplete coverage. Refresh after navigation;
Use read pagination; Blindly snapshots expire per call.

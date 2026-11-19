# Windows headless MCP smoke check

Use an already running headless Sapiens4 backend listening on loopback at
`http://127.0.0.1:4174` and an existing Windows executable. The MCP process is a
stdio bridge to that backend; launching it does not start the backend. Keep the
backend bound to loopback and preserve its existing data and configuration.

## Stdio client launch

From the directory containing the existing `.build/bin/sapiens4.exe`, launch:

```powershell
./.build/bin/sapiens4.exe mcp --url http://127.0.0.1:4174
```

For an MCP client, use that executable as the command, with arguments
`["mcp", "--url", "http://127.0.0.1:4174"]` and stdio transport. Set the working
directory appropriately, or use an absolute executable path. The URL identifies
the HTTP backend, not an HTTP MCP transport endpoint. Exchange one JSON-RPC
object per line on stdin/stdout; keep diagnostics separate from protocol stdout.
No UI, build, runner setup, or credential changes are needed for this check.

## Tool catalog

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `corpora` | Read reachable local and remote corpora: id, name, location, status. | None |
| `sapis` | Read active Sapis, roles, busy state, and workspace tabs. | `corpora` |
| `chat` | Read recent Sapi turns; optionally wait for queued/running work. | `corpora`, `sapi`; optional `limit` (1-50, default 10), `wait` (0-120 seconds, default 0) |
| `send` | Queue a message and start Sapi work; returns a turn id. | `corpora`, `sapi`, `text` |
| `lifecycle` | Pause or activate a corpora; pausing stops running work. | `corpora`, `action` (`pause` or `activate`) |

Use ids returned by `corpora` and `sapis` for subsequent authorized operations.
`send` and `lifecycle` mutate state and are excluded from this read-only smoke
check. Do not invoke Sapiens MCP recursively from a running Sapi to run it.

## Read-only verification

From an independently authorized external stdio client, send these messages in
order, awaiting the response to each request before proceeding:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"windows-headless-smoke","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"corpora","arguments":{}}}
```

Check the actual responses, not just the process exit code:

1. `initialize` returns id 1, no JSON-RPC error, protocol version `2025-11-25`,
   server name `sapiens4`, and tools capability. The notification has no response.
2. `tools/list` returns id 2 and the five tools listed above with input schemas.
3. `corpora` returns id 3, no JSON-RPC error, and `result.isError: false`.
   Parse the JSON in `result.content` text and verify it is a corpora array with
   the expected host records. An empty array does not verify an expected corpora.

The handshake and catalog are served by the bridge itself; only the successful
`corpora` call demonstrates backend access. Stop on errors and record the failed
step. Close client stdin when done. Record host context and actual outcomes
without secrets; documentation of this procedure is not evidence that it passed.
This narrow smoke check is not a regression suite and exercises no chat sends or
lifecycle changes.

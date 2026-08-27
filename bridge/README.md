# Bright Data bridge

TrueForge's remote-MCP client cannot connect to Bright Data's hosted MCP
server (`https://mcp.brightdata.com/mcp`) directly. Reproduced against both
`trueforge@0.1.4` and `trueforge@0.2.0-rc.0`, with both query-token and
`Authorization: Bearer` header auth — every attempt fails the same way:

```
Failed to connect to remote MCP server 'bright-data': failed to connect
(tried streamable-http, sse): [{"transport":"streamable-http","error":
"Timed out after 30000ms"},{"transport":"sse","error":"Timed out after
30000ms"}]
```

The raw HTTP handshake against Bright Data's server completes in under a
second via `curl` in every variant tested (different `Accept` headers,
HTTP/1.1 vs HTTP/2, both MCP protocol versions) — so the hang is inside
TrueForge's own MCP client, not Bright Data's server.

`server.py` sidesteps this by re-exposing the two tools Dispatch needs
(`search_jobs`, `get_job_posting`) as a small local streamable-http MCP
server, using the `mcp` Python SDK. Each tool call does its own
initialize + `tools/call` round trip against Bright Data directly (the
exact handshake proven working via `curl`). TrueForge connects to this
local server without issue — the schemas, session IDs, and error handling
are otherwise unremarkable.

Run standalone for testing:

```
python3 -m venv .venv && .venv/bin/pip install -r bridge/requirements.txt
BRIGHTDATA_API_TOKEN=... .venv/bin/python3 bridge/server.py
```

`scripts/setup.sh` does this automatically as part of the full boot.

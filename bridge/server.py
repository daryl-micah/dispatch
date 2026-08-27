"""Local MCP bridge to Bright Data's remote MCP server.

TrueForge's remote-MCP client times out talking to Bright Data's server
directly (reproduced against both v0.1.4 and v0.2.0-rc.0 of trueforge, with
both query-token and header auth — the raw HTTP handshake itself completes
in under a second via curl, so the hang is in TrueForge's client, not Bright
Data's server). This bridge re-exposes the two tools Dispatch needs as a
local streamable-http MCP server, which TrueForge connects to without issue.

Requires: BRIGHTDATA_API_TOKEN in the environment.
"""

import json
import os

import httpx
from mcp.server.mcpserver import MCPServer

BRIGHTDATA_URL = "https://mcp.brightdata.com/mcp"
TOKEN = os.environ["BRIGHTDATA_API_TOKEN"]

server = MCPServer("bright-data-bridge")


def _bd_call(tool_name: str, arguments: dict) -> dict:
    """Initialize a Bright Data MCP session and call one tool in it."""
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {TOKEN}",
    }
    with httpx.Client(timeout=30) as client:
        init = client.post(
            BRIGHTDATA_URL,
            headers=headers,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "dispatch-bridge", "version": "0.1.0"},
                },
            },
        )
        init.raise_for_status()
        session_id = init.headers["mcp-session-id"]

        call = client.post(
            BRIGHTDATA_URL,
            headers={**headers, "Mcp-Session-Id": session_id},
            json={
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            },
        )
        call.raise_for_status()
        return _parse_sse_json(call.text)


def _parse_sse_json(body: str) -> dict:
    for line in body.splitlines():
        if line.startswith("data: "):
            return json.loads(line[len("data: "):])
    raise ValueError(f"No SSE data line in response: {body!r}")


@server.tool()
def search_jobs(query: str, location: str = "") -> str:
    """Search LinkedIn job listings for a query, optionally scoped to a location.

    Returns raw search result text (titles, URLs, snippets) from Google,
    scoped to linkedin.com/jobs postings.
    """
    scoped_query = f"site:linkedin.com/jobs {query} {location}".strip()
    result = _bd_call("search_engine", {"query": scoped_query, "engine": "google"})
    if "error" in result:
        raise RuntimeError(result["error"])
    return json.dumps(result["result"])


@server.tool()
def get_job_posting(url: str) -> str:
    """Fetch the full text of a job posting page as markdown."""
    result = _bd_call("scrape_as_markdown", {"url": url})
    if "error" in result:
        raise RuntimeError(result["error"])
    return json.dumps(result["result"])


if __name__ == "__main__":
    server.run(transport="streamable-http", host="127.0.0.1", port=8791)

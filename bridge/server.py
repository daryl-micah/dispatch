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
import urllib.parse

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
        return _parse_jsonrpc_response(call)


def _parse_jsonrpc_response(response: httpx.Response) -> dict:
    """Streamable HTTP servers may reply with application/json or SSE framing;
    a client must accept either (MCP spec, streamable-http transport)."""
    content_type = response.headers.get("content-type", "")
    if "application/json" in content_type:
        return response.json()
    for line in response.text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[len("data: "):])
    raise ValueError(f"No SSE data line in response: {response.text!r}")


def _tool_result(response: dict) -> str:
    """Raise on a JSON-RPC error or a tool-execution error (result.isError);
    both represent a failed call and must not surface as tool output."""
    if "error" in response:
        raise RuntimeError(response["error"])
    result = response["result"]
    if result.get("isError"):
        raise RuntimeError(result.get("content", result))
    return json.dumps(result)


@server.tool()
def search_jobs(query: str, location: str = "") -> str:
    """Search LinkedIn job listings for a query, optionally scoped to a location.

    Returns raw search result text (titles, URLs, snippets) from Google,
    scoped to linkedin.com/jobs postings.
    """
    scoped_query = f"site:linkedin.com/jobs {query} {location}".strip()
    response = _bd_call("search_engine", {"query": scoped_query, "engine": "google"})
    return _tool_result(response)


@server.tool()
def get_job_posting(url: str) -> str:
    """Fetch the full text of a LinkedIn job posting page as markdown."""
    host = urllib.parse.urlparse(url).hostname or ""
    if not (host == "linkedin.com" or host.endswith(".linkedin.com")):
        raise ValueError(f"get_job_posting only accepts linkedin.com URLs, got: {url!r}")
    response = _bd_call("scrape_as_markdown", {"url": url})
    return _tool_result(response)


if __name__ == "__main__":
    server.run(transport="streamable-http", host="127.0.0.1", port=8791)

#!/usr/bin/env bash
# Boots TrueForge locally, registers the OpenAI model provider, a trivial
# MCP tool (deepwiki, no auth required) as a smoke test, and the Bright Data
# job-search bridge (see bridge/server.py for why this is a local bridge
# rather than a direct remote MCP registration).
#
# Requires: OPENAI_API_KEY, BRIGHTDATA_API_TOKEN in the environment.
# Never prints either.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="http://localhost:8790"
BRIDGE_URL="http://127.0.0.1:8791/mcp"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Set OPENAI_API_KEY before running this script." >&2
  exit 1
fi
if [ -z "${BRIGHTDATA_API_TOKEN:-}" ]; then
  echo "Set BRIGHTDATA_API_TOKEN before running this script." >&2
  exit 1
fi

echo "Starting Bright Data bridge on port 8791..."
python3 -m venv "${REPO_ROOT}/.venv" 2>/dev/null || true
"${REPO_ROOT}/.venv/bin/pip" install --quiet -r "${REPO_ROOT}/bridge/requirements.txt"
nohup "${REPO_ROOT}/.venv/bin/python3" "${REPO_ROOT}/bridge/server.py" > /tmp/bridge.log 2>&1 &
echo $! > /tmp/bridge.pid

bridge_ready=""
for i in $(seq 1 15); do
  status=$(curl -s -o /dev/null -w "%{http_code}" "${BRIDGE_URL}" || true)
  if [ "$status" = "400" ]; then  # 400 on a bare GET means the server is up
    bridge_ready=1
    break
  fi
  sleep 1
done
if [ -z "$bridge_ready" ]; then
  echo "Bright Data bridge didn't come up within 15s. See /tmp/bridge.log." >&2
  exit 1
fi

echo "Starting TrueForge on port 8790..."
nohup npx -y @truefoundry/trueforge@latest --port 8790 > /tmp/trueforge.log 2>&1 &
echo $! > /tmp/trueforge.pid

ready=""
for i in $(seq 1 20); do
  if curl -s -f -o /dev/null "${BASE_URL}/api/v1/docs"; then
    ready=1
    break
  fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "TrueForge didn't come up within 20s. See /tmp/trueforge.log. Stopping it." >&2
  kill "$(cat /tmp/trueforge.pid)" 2>/dev/null || true
  kill "$(cat /tmp/bridge.pid)" 2>/dev/null || true
  exit 1
fi

echo "Registering OpenAI model provider..."
python3 - <<PYEOF
import json, os, urllib.request

payload = {
    "manifest": {
        "type": "openai",
        "auth": {"api_key": os.environ["OPENAI_API_KEY"]},
        "models": [{
            "model_id": "gpt-5.4-mini",
            "name": "gpt-5-4-mini",
            "properties": {
                "context_length": 400000,
                "max_output_tokens": 128000,
                "reasoning_efforts": ["none", "low", "medium", "high", "xhigh"],
            },
        }],
    }
}
req = urllib.request.Request(
    "${BASE_URL}/api/v1/settings/model-providers",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="PUT",
)
urllib.request.urlopen(req)  # PUT upserts: creates or replaces, always current
PYEOF

echo "Registering deepwiki MCP server (no auth required)..."
mcp_status=$(curl -s -o /tmp/mcp_register.log -w "%{http_code}" -X POST "${BASE_URL}/api/v1/settings/mcp-servers" \
  -H "Content-Type: application/json" \
  -d '{"manifest": {"type": "remote", "name": "deepwiki", "url": "https://mcp.deepwiki.com/mcp", "description": "Read documentation and ask questions about any public GitHub repository."}}') || {
  echo "deepwiki MCP registration request failed (curl transport error). See /tmp/mcp_register.log." >&2
  cat /tmp/mcp_register.log >&2
  exit 1
}
if [ "$mcp_status" != "201" ] && [ "$mcp_status" != "409" ]; then
  echo "deepwiki MCP registration failed (HTTP $mcp_status):" >&2
  cat /tmp/mcp_register.log >&2
  exit 1
fi

echo "Registering bright-data MCP server (via local bridge)..."
bd_status=$(curl -s -o /tmp/bd_register.log -w "%{http_code}" -X PUT "${BASE_URL}/api/v1/settings/mcp-servers" \
  -H "Content-Type: application/json" \
  -d "{\"manifest\": {\"type\": \"remote\", \"name\": \"bright-data\", \"url\": \"${BRIDGE_URL}\", \"description\": \"Search LinkedIn jobs and fetch job posting pages via Bright Data.\"}}") || {
  echo "bright-data MCP registration request failed (curl transport error). See /tmp/bd_register.log." >&2
  cat /tmp/bd_register.log >&2
  exit 1
}
if [ "$bd_status" != "200" ]; then
  echo "bright-data MCP registration failed (HTTP $bd_status):" >&2
  cat /tmp/bd_register.log >&2
  exit 1
fi

echo "TrueForge is up. Chat UI: ${BASE_URL} · API docs: ${BASE_URL}/api/v1/docs"

#!/usr/bin/env bash
# Boots TrueForge locally and registers the OpenAI model provider + a trivial
# MCP tool (deepwiki, no auth required) as a smoke test.
#
# Requires: OPENAI_API_KEY in the environment. Never prints the key.
set -euo pipefail

BASE_URL="http://localhost:8790"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Set OPENAI_API_KEY before running this script." >&2
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
  echo "TrueForge didn't come up within 20s. See /tmp/trueforge.log." >&2
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
  -d '{"manifest": {"type": "remote", "name": "deepwiki", "url": "https://mcp.deepwiki.com/mcp", "description": "Read documentation and ask questions about any public GitHub repository."}}')
if [ "$mcp_status" != "201" ] && [ "$mcp_status" != "409" ]; then
  echo "deepwiki MCP registration failed (HTTP $mcp_status):" >&2
  cat /tmp/mcp_register.log >&2
  exit 1
fi

echo "TrueForge is up. Chat UI: ${BASE_URL} · API docs: ${BASE_URL}/api/v1/docs"

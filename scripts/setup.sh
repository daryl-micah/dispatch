#!/usr/bin/env bash
# Boots TrueForge locally and registers the OpenAI model provider + a trivial
# MCP tool (deepwiki, no auth required) as a smoke test.
#
# Requires: OPENAI_API_KEY in the environment. Never prints the key.
set -euo pipefail

PORT="${PORT:-8790}"
BASE_URL="http://localhost:${PORT}"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Set OPENAI_API_KEY before running this script." >&2
  exit 1
fi

echo "Starting TrueForge on port ${PORT}..."
nohup npx -y @truefoundry/trueforge@latest --port "${PORT}" > /tmp/trueforge.log 2>&1 &
echo $! > /tmp/trueforge.pid

for i in $(seq 1 20); do
  if curl -s -o /dev/null "${BASE_URL}/api/v1/docs"; then
    break
  fi
  sleep 1
done

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
    method="POST",
)
try:
    urllib.request.urlopen(req)
except urllib.error.HTTPError as e:
    if e.code != 409:  # already registered
        raise
PYEOF

echo "Registering deepwiki MCP server (no auth required)..."
curl -s -X POST "${BASE_URL}/api/v1/settings/mcp-servers" \
  -H "Content-Type: application/json" \
  -d '{"manifest": {"type": "remote", "name": "deepwiki", "url": "https://mcp.deepwiki.com/mcp", "description": "Read documentation and ask questions about any public GitHub repository."}}' \
  -o /dev/null -w "  -> %{http_code}\n" || true

echo "TrueForge is up at ${BASE_URL} (docs at ${BASE_URL}/api/v1/docs)."

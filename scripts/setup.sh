#!/usr/bin/env bash
# Boots TrueForge locally, registers the OpenAI model provider, a trivial
# MCP tool (deepwiki, no auth required) as a smoke test, the Bright Data
# job-search bridge (see bridge/server.py for why this is a local bridge
# rather than a direct remote MCP registration), and the resume-scoring /
# cover-letter-rendering service (see scoring/NOTES.md for why this runs
# outside TrueForge's sandbox).
#
# Requires: OPENAI_API_KEY, BRIGHTDATA_API_TOKEN in the environment.
# Never prints either.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="http://localhost:8790"
BRIDGE_URL="http://127.0.0.1:8791/mcp"
SCORING_URL="http://127.0.0.1:8792/mcp"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Set OPENAI_API_KEY before running this script." >&2
  exit 1
fi
if [ -z "${BRIGHTDATA_API_TOKEN:-}" ]; then
  echo "Set BRIGHTDATA_API_TOKEN before running this script." >&2
  exit 1
fi

# Only kills the PID if it's still the expected local service — a stale PID
# file whose PID got reused by an unrelated process must not be killed blind.
kill_local_service_pid() {
  pidfile="$1"
  pattern="$2"
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    if ps -p "$pid" -o args= 2>/dev/null | grep -q "$pattern"; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
}

# Called on every failure path once services may have started, so a failed
# run never leaves a process (and its port) occupied for the next attempt.
cleanup_all() {
  kill "$(cat /tmp/trueforge.pid 2>/dev/null)" 2>/dev/null || true
  kill_local_service_pid /tmp/bridge.pid "bridge/server.py"
  kill_local_service_pid /tmp/scoring.pid "scoring/server.py"
}

python3 -m venv "${REPO_ROOT}/.venv" 2>/dev/null || true
"${REPO_ROOT}/.venv/bin/pip" install --quiet -r "${REPO_ROOT}/bridge/requirements.txt" -r "${REPO_ROOT}/scoring/requirements.txt"

echo "Starting Bright Data bridge on port 8791..."
kill_local_service_pid /tmp/bridge.pid "bridge/server.py"
sleep 1
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
  echo "Bright Data bridge didn't come up within 15s. See /tmp/bridge.log. Stopping it." >&2
  cleanup_all
  exit 1
fi

echo "Starting scoring service on port 8792..."
kill_local_service_pid /tmp/scoring.pid "scoring/server.py"
sleep 1
nohup "${REPO_ROOT}/.venv/bin/python3" "${REPO_ROOT}/scoring/server.py" > /tmp/scoring.log 2>&1 &
echo $! > /tmp/scoring.pid

scoring_ready=""
for i in $(seq 1 15); do
  status=$(curl -s -o /dev/null -w "%{http_code}" "${SCORING_URL}" || true)
  if [ "$status" = "400" ]; then
    scoring_ready=1
    break
  fi
  sleep 1
done
if [ -z "$scoring_ready" ]; then
  echo "Scoring service didn't come up within 15s. See /tmp/scoring.log. Stopping it." >&2
  cleanup_all
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
  cleanup_all
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
  cleanup_all
  exit 1
}
if [ "$mcp_status" != "201" ] && [ "$mcp_status" != "409" ]; then
  echo "deepwiki MCP registration failed (HTTP $mcp_status):" >&2
  cat /tmp/mcp_register.log >&2
  cleanup_all
  exit 1
fi

echo "Registering bright-data MCP server (via local bridge)..."
bd_status=$(curl -s -o /tmp/bd_register.log -w "%{http_code}" -X PUT "${BASE_URL}/api/v1/settings/mcp-servers" \
  -H "Content-Type: application/json" \
  -d "{\"manifest\": {\"type\": \"remote\", \"name\": \"bright-data\", \"url\": \"${BRIDGE_URL}\", \"description\": \"Search LinkedIn jobs and fetch job posting pages via Bright Data.\"}}") || {
  echo "bright-data MCP registration request failed (curl transport error). See /tmp/bd_register.log." >&2
  cat /tmp/bd_register.log >&2
  cleanup_all
  exit 1
}
if [ "$bd_status" != "200" ]; then
  echo "bright-data MCP registration failed (HTTP $bd_status):" >&2
  cat /tmp/bd_register.log >&2
  cleanup_all
  exit 1
fi

echo "Registering scoring MCP server..."
scoring_status=$(curl -s -o /tmp/scoring_register.log -w "%{http_code}" -X PUT "${BASE_URL}/api/v1/settings/mcp-servers" \
  -H "Content-Type: application/json" \
  -d "{\"manifest\": {\"type\": \"remote\", \"name\": \"scoring\", \"url\": \"${SCORING_URL}\", \"description\": \"Score resumes against job listings and render tailored cover letters as PDFs.\"}}") || {
  echo "scoring MCP registration request failed (curl transport error). See /tmp/scoring_register.log." >&2
  cat /tmp/scoring_register.log >&2
  cleanup_all
  exit 1
}
if [ "$scoring_status" != "200" ]; then
  echo "scoring MCP registration failed (HTTP $scoring_status):" >&2
  cat /tmp/scoring_register.log >&2
  cleanup_all
  exit 1
fi

echo "TrueForge is up. Chat UI: ${BASE_URL} · API docs: ${BASE_URL}/api/v1/docs"

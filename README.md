# Dispatch — Licence to Apply

An agent that runs your job search as an ongoing operation: scrapes live
listings, tailors a pitch per role in a sandbox, then stops and asks
permission before anything leaves the building.

Built on [TrueForge](https://github.com/truefoundry/trueforge) for The Agent
Harness Hackathon.

## What it does

1. **Scrape** — Bright Data pulls live LinkedIn listings for a query.
2. **Score** — sandboxed script ranks roles against your resume, drops duplicates.
3. **Tailor** — renders a cover letter per shortlisted role.
4. **Approve** — full preview of the outbound email; approve, edit, or reject.
5. **Dispatch** — sends, writes the ledger, appends the audit log. Never sends
   the same role twice.

The send target is your own inbox (set via env var) — never a real employer.

## Running it

```
export OPENAI_API_KEY=sk-...
export BRIGHTDATA_API_TOKEN=...
./scripts/setup.sh
```

Boots TrueForge locally (SQLite, standalone mode) on `localhost:8790`,
registers the OpenAI model provider, and attaches two MCP servers:
`deepwiki` (smoke test, no auth) and `bright-data` (job search — see
[bridge/](bridge/) for why this runs through a local bridge process rather
than a direct remote-MCP registration). Chat UI at `http://localhost:8790`,
API docs at `http://localhost:8790/api/v1/docs`.

Then create an agent with the `bright-data` tool attached and ask it to
find jobs — see `scripts/setup.sh`'s output for the exact API calls, or use
the chat UI directly.

## Qodo Code Review Evidence

Every PR on this repo is reviewed via `/agentic_review` before merge.

| PR | Review | Flagged | Fix |
|----|--------|---------|-----|
| [#1](https://github.com/daryl-micah/dispatch/pull/1) | [round 1](https://github.com/daryl-micah/dispatch/pull/1#pullrequestreview) | Readiness loop ignored HTTP failures; MCP registration errors silently swallowed (`\|\| true`); re-running with a new `OPENAI_API_KEY` left the stale key in place; unrequested `PORT` override; README pointed the chat UI at the API docs path | Readiness loop now fails closed with `curl -f` and a timeout exit; MCP registration checks the status code and exits nonzero on real failures; provider registration switched from POST+catch-409 to PUT (upsert), so reruns always pick up the current key; removed the `PORT` override; fixed the README URL |
| [#1](https://github.com/daryl-micah/dispatch/pull/1) | [round 2](https://github.com/daryl-micah/dispatch/pull/1#pullrequestreview) | A readiness timeout left the background TrueForge process running instead of being killed; a curl transport error inside the `mcp_status=$(...)` assignment would abort the script under `set -e` without printing the diagnostic log | Timeout path now kills the tracked PID before exiting; the MCP curl call has explicit transport-error handling that prints the log before exiting |
| [#2](https://github.com/daryl-micah/dispatch/pull/2) | [review](https://github.com/daryl-micah/dispatch/pull/2#pullrequestreview) | The bridge only parsed SSE-framed responses, so a valid `application/json` reply raised instead of returning; `result.isError` from a failed Bright Data tool call was serialized as if it were success; a stale bridge process on port 8791 from a prior run silently kept an old `BRIGHTDATA_API_TOKEN` on rerun; `get_job_posting` forwarded any caller-supplied URL to an authenticated scrape tool with no host check, letting the bridge credential be used to scrape arbitrary sites; the bridge's own readiness-timeout path didn't kill the process it had just started. (A fifth finding, an added `.env.*` gitignore rule, was a pre-existing local edit unrelated to this PR's actual scope — left as-is.) | Response parsing now branches on `Content-Type` before falling back to SSE framing; tool results are checked for `isError` and raised as failures; `setup.sh` now kills any previously recorded bridge PID before starting a new one; `get_job_posting` validates the URL host is `linkedin.com` (or a subdomain) before calling out; the bridge's readiness-timeout path now kills its own PID |

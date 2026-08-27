# Dispatch — Licence to Apply

An agent that runs your job search as an ongoing operation: scrapes live
listings, tailors a pitch per role in a sandbox, then stops and asks
permission before anything leaves the building.

Built on [TrueForge](https://github.com/truefoundry/trueforge) for The Agent
Harness Hackathon.

## What it does

1. **Scrape** — Bright Data MCP pulls live LinkedIn listings for a query.
2. **Score** — sandboxed script ranks roles against your resume, drops duplicates.
3. **Tailor** — renders a cover letter per shortlisted role.
4. **Approve** — full preview of the outbound email; approve, edit, or reject.
5. **Dispatch** — sends, writes the ledger, appends the audit log. Never sends
   the same role twice.

The send target is your own inbox (set via env var) — never a real employer.

## Running it

```
export OPENAI_API_KEY=sk-...
./scripts/setup.sh
```

Boots TrueForge locally (SQLite, standalone mode) on `localhost:8790`,
registers the OpenAI model provider, and attaches `deepwiki` as a smoke-test
MCP tool (no auth required). Chat UI at `http://localhost:8790`, API docs at
`http://localhost:8790/api/v1/docs`.

## Qodo Code Review Evidence

Every PR on this repo is reviewed via `/agentic_review` before merge.

| PR | Review | Flagged | Fix |
|----|--------|---------|-----|
| [#1](https://github.com/daryl-micah/dispatch/pull/1) | [review](https://github.com/daryl-micah/dispatch/pull/1#pullrequestreview) | Readiness loop ignored HTTP failures; MCP registration errors silently swallowed (`\|\| true`); re-running with a new `OPENAI_API_KEY` left the stale key in place; unrequested `PORT` override; README pointed the chat UI at the API docs path | Readiness loop now fails closed with `curl -f` and a timeout exit; MCP registration checks the status code and exits nonzero on real failures; provider registration switched from POST+catch-409 to PUT (upsert), so reruns always pick up the current key; removed the `PORT` override; fixed the README URL |

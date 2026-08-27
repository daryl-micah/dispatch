# Why this bypasses TrueForge's sandbox

Day 2 of the build plan called for the agent to write and run scoring/PDF
code inside TrueForge's sandbox (`config.sandbox.enabled: true`). That
sandbox cannot initialize in this environment — confirmed as a real bug in
the sandbox's network relay, not a local misconfiguration.

## The bug

Every sandboxed exec first needs a one-time bootstrap: TrueForge creates a
Python venv under the sandbox root and pip-installs `pydantic` into it
(`ensureVenv` in `@truefoundry/trueforge`'s `main.js`). That install fails:

```
Failed to pip install pydantic>=2.0.0,<3.0.0 into sandbox .venv:
ProxyError('Cannot connect to proxy.', NewConnectionError(...
Connection refused))
```

### Trace

TrueForge's local sandbox is built on `@anthropic-ai/sandbox-runtime`
(bwrap + a local HTTP/SOCKS proxy that enforces a domain allowlist —
`pypi.org` and `github.com` families are allowed by default). Reproduced
outside TrueForge by driving `SandboxManager` directly with the same
config TrueForge uses:

1. **First bug (fixed):** the venv itself failed to create —
   `ensurepip` needs `/usr/share/python-wheels` (where Ubuntu's
   `python3.12-venv` package stores its bundled pip/setuptools wheels),
   which isn't in TrueForge's Linux `allowRead` list (only
   `/usr/lib`, `/usr/local`, `/etc`, `/dev`, `/proc`, `/sys`, a handful of
   bin dirs). Confirmed by adding that path to `allowRead` in a standalone
   repro — venv creation then succeeds.

2. **Second bug (not fixed):** once the venv exists, the pip install
   itself fails identically whether driven by `pip` or a bare `curl` —
   ruling out anything pip-specific. The proxy chain is: the sandboxed
   process gets an env var pointing at `http://user:pass@localhost:<port>`;
   that port is served by a `socat` process *inside* the sandbox relaying
   to a Unix domain socket, which a second `socat` process *outside* the
   sandbox relays to a local "mux" proxy that actually makes the
   allowlisted request. Requests through this chain get a TCP connection
   accepted, then the CONNECT tunnel aborts mid-handshake
   (`Proxy CONNECT aborted` / `RemoteDisconnected`) — reproduced with both
   Homebrew's `socat` and the standard `apt` package at `/usr/bin/socat`,
   so it isn't a PATH/install-location issue. It's inside the relay chain
   itself.

Both bugs were confirmed with `SRT_DEBUG=true` logging and a minimal
Node script calling `SandboxManager.initialize()` /
`SandboxManager.wrapWithSandboxArgv()` the same way TrueForge's
`runSupervisorSession` does, isolating them from anything in this repo's
own code.

## The workaround

`scoring/server.py` is a local MCP server (same pattern as
`bridge/server.py` for Bright Data) exposing the scoring/rendering step as
fixed tools instead of agent-written sandboxed code:

- `parse_resume` — extract text from a resume PDF
- `score_jobs` — keyword-overlap ranking + duplicate-listing removal
- `render_cover_letter` — render agent-written letter text to a PDF

The agent still does the actual judgment (reading job descriptions,
writing the tailored letter); this only does the mechanical, deterministic
parts — arguably the right split regardless of the sandbox bug.

## If the sandbox is fixed upstream

This workaround can be dropped once TrueForge/sandbox-runtime ships a fix.
The two things to check: `/usr/share/python-wheels` in
`ALLOW_READ_BY_PLATFORM.linux`, and whatever the mux/socat relay chain is
doing to abort CONNECT tunnels.

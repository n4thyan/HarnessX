# Current HarnessX baseline

HarnessX is populated and usable as a Studio-only debugging and testing baseline.

## Included in the current Studio plugin

- Dockable HarnessX dashboard
- Authenticated live-traffic polling
- Script inspector
- Source instrumentation through `ScriptEditorService:UpdateSourceAsync()`
- Configurable `UNC` or `RemoteProxy` rewrite style
- Undo-aware batch rewrites
- Observe/mock and performance-profile controls
- Source backup controls
- Trace injection
- Remote discovery and fuzz-session controls

## Runtime and bridge capabilities

`roblox/Core.lua`, the proxy modules, and `server/main.py` provide:

- Manual `RemoteProxy` wrappers
- Folder hierarchy generation through `AutoProxy`
- Cooperative stack snapshots
- Server-Sent Events traffic streaming
- Safe process metrics
- Instance, GC, and harness-owned connection diagnostics
- Rolling RemoteFunction latency statistics
- Timestamped source backups
- Fuzz-session coordination and reporting

The current compact plugin consumes traffic through authenticated polling. The bridge also retains SSE and stack-dump APIs, but the present plugin does not consume those endpoints.

## Security boundary

All Luau entry points remain guarded by `RunService:IsStudio()` and the `HarnessXEnabled` opt-in attribute. The Flask bridge remains loopback-only and token-authenticated. Process-memory reads and writes are not supported.

## Validation boundary

Python syntax and encoder tests were run against the generated source before publication. Repository checks confirm the configuration, Studio guards, runtime files, Flask bridge, documentation, and plugin source. Automated CI now runs on pushes and pull requests targeting `main`. A Roblox Studio playtest is still required for Luau runtime behavior and DockWidget rendering verification.

## Audit remediation

- Default bridge credentials are replaced on first start or supplied through `HARNESSX_BRIDGE_TOKEN`.
- Browser origins and CORS preflights are rejected.
- Runtime traffic is rate-limited, size-limited, bounded, and retried with a fixed cap.
- SUNC latency separates target-remote time from HarnessX preflight overhead.
- Source auto-rewrite is disabled by default and the rewriter masks quoted strings, long strings, line comments, and block comments.
- Backups use path-segment arrays and deterministic collision suffixes.
- Completed fuzz sessions are retained in a bounded history.
- CI performs Python tests and repository security-contract checks.

A Roblox Studio playtest is still required to validate Luau behavior and DockWidget rendering.

# Current HarnessX baseline

The repository is populated and usable as the initial HarnessX development baseline.

## Included in the current Studio plugin

- Dockable HarnessX dashboard
- Live traffic polling
- Script inspector
- Source instrumentation through `ScriptEditorService:UpdateSourceAsync()`
- Undo-aware batch rewrites
- Observe/mock and performance-profile controls
- Source backup controls
- Trace injection
- Remote discovery and fuzz-session controls

## Runtime and bridge capabilities

`roblox/Core.lua` and `server/main.py` also provide:

- Cooperative stack snapshots
- Server-Sent Events traffic streaming
- Safe process metrics
- Instance, GC, and harness-owned connection diagnostics
- Rolling RemoteFunction latency statistics
- Timestamped source backups
- Fuzz-session coordination and reporting

The compact plugin currently consumes traffic through authenticated polling. The SSE and stack-dump endpoints remain available for the next dashboard iteration.

## Validation boundary

Python syntax and encoder tests were run against the generated source before publication. GitHub API reads confirmed the published configuration, Studio guards, Core runtime, Flask bridge, README, and plugin commit. A Roblox Studio playtest is still required for Luau runtime and DockWidget rendering verification.

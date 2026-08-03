# HarnessX validation

Passed:
- Required file presence
- config.json parsing and new section checks
- Exact RunService:IsStudio() first-line guard on every Luau file
- Python syntax compilation
- Loopback-only server constant
- Authentication middleware presence
- Fuzzing, backup, and profiling route presence
- Disabled memory-read endpoint presence
- No memory-write endpoint
- Fuzzer dashboard/source-backup/trace-injection structural checks
- GetPerformanceStats and rolling p95 structural checks
- Python fuzz-session create/claim/status/stop smoke flow
- Python timestamped backup smoke flow
- Encoder round-trip checks for 1, 2, 3, 4, and 16 rounds

Not performed in this environment:
- Roblox Studio/Luau runtime execution
- Live playtest client/server fuzz run
- DockWidget rendering verification


Automated on every push and pull request:
- Python syntax compilation
- Encoder round trips
- Flask authentication checks
- Browser-origin and CORS regression checks
- Disabled memory endpoint check
- Studio guard and configuration contract checks
- Current-tree scan for unsupported process-memory and engine-hook APIs

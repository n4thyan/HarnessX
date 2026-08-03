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
- Reproducible plugin artifact generation for identical inputs
- Artifact, manifest, and SHA256SUMS consistency checks
- Tampered plugin artifact rejection

Not performed in this environment:
- Roblox Studio/Luau runtime execution
- Live playtest client/server fuzz run
- DockWidget rendering verification
- GitHub artifact-attestation verification outside a release workflow

Automated on every push and pull request:
- Python syntax compilation
- Encoder round trips
- Flask authentication checks
- Browser-origin and CORS regression checks
- Disabled memory endpoint check
- Studio guard and configuration contract checks
- Current-tree scan for unsupported process-memory and engine-hook APIs
- Source-rewriter guards for RemoteProxy recursion, long strings/comments, directive placement, and Luau-compatible trace patterns
- Deterministic provenance fixture build and local checksum verification
- Provenance tamper-detection tests

Automated for version tags and manual release builds:
- Deterministic `HarnessXPlugin.lua` generation
- Source and artifact SHA-256 manifest generation
- `SHA256SUMS` generation
- Local verification before upload
- GitHub artifact upload
- GitHub build-provenance attestation

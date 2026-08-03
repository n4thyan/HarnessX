# Executor builds

HarnessX does not provide or support a live Roblox executor build.

This repository is intentionally limited to Roblox Studio. Every Luau entry point retains the `RunService:IsStudio()` guard and the separate `HarnessXEnabled` opt-in attribute. The Python bridge remains bound to `127.0.0.1`, requires the configured debug token, and does not provide arbitrary process-memory access.

## Unsupported modifications

The HarnessX project does not support modifications that:

- remove the Studio execution boundary;
- replace or globally intercept Roblox engine methods;
- use executor-only metatable or runtime-hook APIs;
- inject code into the published Roblox client;
- read from or write to another process's memory; or
- add live-client exploitation features.

No implementation instructions or code for those modifications are included in this repository.

## Supported alternatives

For debugging games you own, use Studio playtests together with:

- the UNC and SUNC source wrappers;
- the manual `RemoteProxy` wrapper;
- `AutoProxy.wrapFolder()` for opt-in folder snapshots;
- the source-rewriter plugin;
- the authenticated loopback bridge;
- bounded fuzz sessions and diagnostics; and
- cooperative stack and performance reporting.

These mechanisms preserve the Studio-only security boundary and use supported Roblox APIs.

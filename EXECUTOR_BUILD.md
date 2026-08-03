# Why HarnessX does not have a "live" or executor build

HarnessX is intentionally scoped to Roblox Studio only. This file exists to
document that decision so it isn't re-litigated by accident in a future PR.

## The guards are load-bearing, not decorative

Every runtime Luau file in `roblox/` opens with the same two lines:

```lua
if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end
```

Each check does a different job:

- **`RunService:IsStudio()`** — refuses to run inside a live server or a real
  client connected to a live server. This is the check that keeps HarnessX
  from ever touching production traffic.
- **`HarnessXEnabled` attribute** — an explicit, per-place opt-in. Even inside
  Studio, HarnessX stays off unless a maintainer has deliberately turned it on
  for that place file.

The Flask bridge (`server/main.py`) adds a third, independent layer:

- It **refuses to bind to anything other than `127.0.0.1`** (`raise SystemExit`
  if the configured host isn't loopback), so it can never be reached from
  another machine or from a live game server.
- Every `/v1/*` route requires a constant-time-compared `X-Debug-Token`.

These three layers are deliberately redundant. Removing any one of them
(e.g. stripping the `IsStudio()` check, dropping the opt-in attribute, or
binding the bridge to `0.0.0.0`) would not "unlock a feature" — it would
turn a local debugging/fuzzing tool into something that can fire arbitrary
or fuzzed remote calls against a real, live server. That is a materially
different and unsupported use case:

- It would send unauthorized automated traffic to production game servers,
  which violates the Roblox Terms of Service.
- It could affect real players' game state or data.
- It removes the isolation that makes fuzzing safe to run in the first place.

**There is no supported "executor" or "live" build of HarnessX, and none is
planned.** Contributions that weaken, bypass, or make optional any of the
three guards above will be rejected.

## If you want to test against something closer to production

Use a dedicated test place (a separate published place, Team Test, or a
private server) instead of removing the guards. HarnessX's Studio checks
would still need to gate that context appropriately — this is a separate,
deliberate design change, not a bypass, and should be scoped to a test
environment your team controls, never a live game with real players.


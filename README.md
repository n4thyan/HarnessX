# HarnessX

A Studio-only Roblox network debugging, automated testing, fuzzing, source-instrumentation, and performance-profiling toolkit. HarnessX uses supported Roblox APIs, a loopback-only Python bridge, and an explicit `RunService:IsStudio()` lock.

## Security boundary

Every runtime Luau file starts with:

```lua
if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end
```

`HarnessXEnabled` is an additional opt-in switch inside Studio. It does not bypass the Studio guard.

```text
config.json
roblox/Core.lua
roblox/Encoder.lua
roblox/UNC.lua
roblox/SUNC.lua
roblox/RemoteProxy.lua
roblox/AutoProxy.lua
roblox/Fuzzer.lua
roblox/Fuzzer.client.lua
roblox/Plugin.lua
server/encoder.py
server/scanner.py
server/main.py
README.md
```

## Required Studio layout

```text
ReplicatedStorage
└── HarnessX
    ├── Encoder        ModuleScript
    ├── UNC            ModuleScript
    ├── SUNC           ModuleScript
    ├── RemoteProxy    ModuleScript
    ├── AutoProxy      ModuleScript
    └── Fuzzer         ModuleScript

ServerScriptService
└── Core               Script

StarterPlayer
└── StarterPlayerScripts
    └── FuzzerClient   LocalScript
```

Paste `roblox/Fuzzer.client.lua` into `FuzzerClient`.

The separate LocalScript is necessary because Roblox defines `RemoteEvent:FireServer()` and `RemoteFunction:InvokeServer()` as client-to-server operations. The editor plugin controls tests, while the LocalScript performs calls in the supported playtest-client context.

## Start the bridge

HarnessX requires Python 3.10 or newer. Install the pinned direct dependencies:

```bat
pip install -r requirements.lock
```

Start the server from the project root:

```bat
python server\main.py
```

Enable:

```text
Game Settings → Security → Allow HTTP Requests
```

On first start, the bridge replaces the committed placeholder token with a random token and writes it to `config.json`. You can instead supply `HARNESSX_BRIDGE_TOKEN` as an environment variable. The bridge refuses to continue with an invalid token.

Set the same token in Studio from the Command Bar before loading Core or the plugin:

```lua
game:SetAttribute("HarnessXEnabled", true)
game:SetAttribute("HarnessXBridgeToken", "copy-the-token-from-config-json")
```

`HarnessXEnabled` is an additional Studio opt-in and never bypasses `RunService:IsStudio()`. The token protects the loopback HTTP service from unrelated local processes, but code already executing inside the same Studio DataModel can read attributes and use HarnessX transport remotes. Do not run untrusted place code while HarnessX is enabled.

The bridge intentionally rejects browser-origin requests and does not emit permissive CORS headers. Do not add `flask-cors` or wildcard origins for convenience.

## Plugin installation

1. Place `roblox/Plugin.lua` into a temporary Script.
2. Select the Script.
3. Choose **Plugins → Save as Local Plugin**.
4. Remove the temporary Script.
5. Restart or reload the plugin after replacing its source.

The plugin retains the previous dashboard tabs and adds **Fuzzer**.

## Wrapper style

The plugin supports two source-rewrite styles through `config.json`:

```json
"plugin": {
  "wrapper_style": "UNC"
}
```

Use `"UNC"` to rewrite calls through `UNC.FireServer()` and `SUNC.InvokeServer()`. Use `"RemoteProxy"` to rewrite calls through the manual `RemoteProxy.wrap()` table wrapper.

## Fuzzer tab

The Fuzzer tab scans the DataModel for eligible `RemoteEvent` and `RemoteFunction` instances. Remotes carrying the configured `HarnessXIgnore` attribute, or located inside the harness itself, are excluded.

### Select a remote

Open the target selector and choose a remote, then define the argument schema explicitly. HarnessX does not infer a reliable remote contract from source code; the schema editor is authoritative.

### Schema format

Enter one descriptor per line:

```text
number:min=0,max=100
string:length=16
boolean
Vector3:min=-50,max=50
CFrame:min=-20,max=20,maxRotation=90
Instance:path=Workspace.TestPart
EnumItem:value=Enum.KeyCode.E
```

Blank lines and lines beginning with `#` are ignored.

A line may also be a raw JSON descriptor:

```json
{"__type":"RandomNumber","min":-1,"max":1}
```

Supported materialized values include:

- Random numbers
- Random strings
- Random booleans
- Random `Vector3`
- Random `CFrame`
- Instances resolved from a DataModel path
- Enum items resolved from paths such as `Enum.KeyCode.E`

The wrappers also expose:

```lua
UNC.Materialize(value)
UNC.BuildArguments(template)
SUNC.Materialize(value)
SUNC.BuildArguments(template)
```

A literal string `"random"` produces a random number. Typed random values should use a descriptor such as:

```lua
{
    __type = "Random",
    expectedType = "Vector3",
    min = -10,
    max = 10,
}
```

### Start a run

1. Choose a remote.
2. Define the argument schema.
3. Enter calls per second.
4. Enter duration.
5. Click **Start fuzzing**.
6. Start a Studio playtest if one is not already running.

The server queues the session. The first Studio playtest client to claim it executes the calls through `UNC.FireServer()` or `SUNC.InvokeServer()`.

The configured hard cap is:

```json
"fuzzer": {
  "default_rate": 5,
  "max_rate": 100,
  "default_duration_seconds": 30
}
```

The dashboard displays:

- Session state
- Total completed attempts
- Errors
- Average measured call latency

Each attempt appears in the traffic feed with a `[FUZZ]` prefix. The ordinary UNC/SUNC traces remain visible as well.

### Stop a run

Click **Stop fuzzing**. The playtest runner checks the control state approximately once per second, so a few final attempts can occur before it observes the stop.

## Fuzzing API

Create a session:

```text
POST /v1/fuzz/start
```

Example JSON:

```json
{
  "target": "ReplicatedStorage.Remotes.GetInventory",
  "target_segments": [
    "ReplicatedStorage",
    "Remotes",
    "GetInventory"
  ],
  "target_class": "RemoteFunction",
  "arg_types": [
    {
      "__type": "RandomNumber",
      "min": 1,
      "max": 100
    }
  ],
  "rate": 5,
  "duration": 30
}
```

Stop:

```text
POST /v1/fuzz/stop/{session_id}
```

Status:

```text
GET /v1/fuzz/status/{session_id}
```

Internal runtime coordination also uses:

```text
POST /v1/fuzz/claim
POST /v1/fuzz/report/{session_id}
```

## SUNC latency profiling

`Core.lua` records every SUNC trace containing `durationMs`. Samples are retained per RemoteFunction path for the configured rolling window:

```json
"profiling": {
  "enabled": true,
  "window_seconds": 60
}
```

For each remote it calculates:

- Sample count
- Average latency
- Minimum latency
- Maximum latency
- 95th percentile latency

The runtime exposes:

```text
ReplicatedStorage.HarnessX.Transport.GetPerformanceStats
```

Example:

```lua
local transport = game.ReplicatedStorage.HarnessX.Transport
local stats = transport.GetPerformanceStats:Invoke()

for remotePath, remoteStats in stats.remotes do
    print(
        remotePath,
        remoteStats.averageMs,
        remoteStats.p95Ms
    )
end
```

The latest aggregate is available from Flask:

```text
GET /v1/profiling/sunc
```

The dashboard’s **Controls → View SUNC latency statistics** button opens the latest JSON snapshot.

### Interpreting p95

A p95 of `80 ms` means 95% of calls in the active rolling window completed in `80 ms` or less. Compare p95 with the average:

- Similar average and p95 usually indicates stable latency.
- A much higher p95 indicates intermittent slow calls or outliers.
- A rising p95 with a stable minimum can indicate queueing, contention, or expensive edge cases.

## Backup system

The plugin’s toolbar and Script Inspector contain **Backup All** controls.

The plugin reads the editor source of every eligible Script, LocalScript, and ModuleScript and sends one authenticated payload to:

```text
POST /v1/backup/sources
```

The server writes a timestamped folder under:

```json
"backup": {
  "output_dir": "./backups",
  "max_backups": 50
}
```

Example output:

```text
backups/
└── 20260802T201500.123456Z-a1b2c3d4/
    ├── manifest.json
    ├── ServerScriptService/
    │   └── Core.lua
    └── ReplicatedStorage/
        └── Modules/
            └── Inventory.lua
```

Paths are sanitized before being written. Old timestamped folders beyond `max_backups` are deleted.

The bridge request-size limit is increased to 8 MiB to support ordinary project backups. Very large projects should be backed up through Rojo/Git instead of increasing this without limit.

## Inject Trace

Select an instrumented script in the Script Inspector and click **Inject trace**.

The plugin uses `ScriptEditorService:UpdateSourceAsync()` and a `ChangeHistoryService` recording. It wraps each current source-level call expression:

```lua
SUNC.InvokeServer(remote, value)
```

as an expression-preserving trace:

```lua
__HarnessTrace("SUNC", "remote", function()
    return SUNC.InvokeServer(remote, value)
end)
```

The helper prints:

```text
[Harness] Calling
[Harness] Call finished
```

and preserves multiple return values and raised errors.

Trace injection is intentionally one-shot per script. Use Studio Undo or source control to remove it. If new wrapper calls are added later, remove the trace marker or restore the script before reinjecting.

## Dynamic controls

The dashboard can change the in-memory SUNC mode and active performance profile without restarting Flask:

```text
POST /v1/config/update
```

These changes are not written back to `config.json`.

## Existing diagnostics

The suite retains:

```text
GET  /v1/metrics
GET  /v1/diagnostics
POST /v1/instance_counts
POST /v1/gc_stats
POST /v1/connection_counts
POST /v1/diagnostics/trigger
```

It also retains cooperative stack snapshots and the live SSE traffic stream.

## Memory boundary

This remains disabled:

```text
POST /v1/memory/read
```

It always returns HTTP 403.

There is no memory-write route.

## Repository

Project repository: `n4thyan/HarnessX`.

## License

HarnessX is licensed under the MIT License. See [`LICENSE`](LICENSE).

## Studio-only execution

HarnessX remains Studio-only.

The `HarnessXEnabled` attribute is an additional opt-in gate inside Studio. It does not bypass `RunService:IsStudio()`.

Running HarnessX in a published live client is not supported out of the box. To run it in a live client, you would need to maintain a separate unsupported fork with the Studio guards manually removed from the Luau files. This configuration is not tested, recommended, or supported by the HarnessX project. ;-)


## Runtime resilience

The Core traffic queue is bounded. When the configured limit is reached, the oldest queued record is dropped and the dropped-record count is reported in runtime status. Failed bridge batches are retried with bounded exponential backoff; they are discarded after the configured retry cap.

SUNC profiling reports `remoteDurationMs`, `preflightDurationMs`, and `totalDurationMs`. The compatibility field `durationMs` now represents only the target RemoteFunction call. Observe mode no longer blocks the game call on the localhost preflight. Mock and fuzz modes retain synchronous preflight because they may change behavior.

The AutoProxy quick-start table is created in `Fuzzer.client.lua`, where client-to-server remote methods are valid. It is available as `_G.HarnessXRemotes` in that client Luau VM when `ReplicatedStorage.Remotes` exists.

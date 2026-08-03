# HarnessX

A Studio-only Roblox network debugging, automated testing, fuzzing, source-instrumentation, and performance-profiling toolkit. HarnessX uses supported Roblox APIs, a loopback-only Python bridge, and an explicit `RunService:IsStudio()` lock.

Security boundary (global-hooks branch)
---------------------------------------

This branch introduces an advanced opt‑in toggle for developers who want to run
HarnessX outside the Studio sandbox.

Every runtime Luau file starts with:

```lua
if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

```text
config.json
roblox/Core.lua
roblox/Encoder.lua
roblox/UNC.lua
roblox/SUNC.lua
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
    ├── SUNC            ModuleScript
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

Install Python dependencies:

```bat
pip install flask psutil
```

Start the server from the project root:

```bat
python server\main.py
```

Enable:

```text
Game Settings → Security → Allow HTTP Requests
```

The same token must appear in:

```text
config.json
roblox/Core.lua
roblox/Plugin.lua
```

## Plugin installation

1. Place `roblox/Plugin.lua` into a temporary Script.
2. Select the Script.
3. Choose **Plugins → Save as Local Plugin**.
4. Remove the temporary Script.
5. Restart or reload the plugin after replacing its source.

The plugin retains the previous dashboard tabs and adds **Fuzzer**.

## Fuzzer tab

The Fuzzer tab scans the DataModel for eligible `RemoteEvent` and `RemoteFunction` instances. Remotes carrying the configured `HarnessXIgnore` attribute, or located inside the harness itself, are excluded.

### Select a remote

Open the target selector and choose a remote. The plugin performs a heuristic source scan to estimate its argument count. Direct method calls and rewritten `UNC.FireServer()` / `SUNC.InvokeServer()` calls are both considered.

Argument detection cannot resolve every dynamically generated remote reference. The schema editor remains authoritative.

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

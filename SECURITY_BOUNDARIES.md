# HarnessX Security Boundaries, Guardrails & Threat Model

This document explains every significant HarnessX guardrail in two separate ways:

1. **Trust level** — how much protection the guardrail actually provides against misuse or tampering.
2. **Control type** — whether the guardrail is a hard boundary, runtime toggle, startup setting, per-instance opt-out, manual action, or build-time verification step.

It is intended to sit alongside the main README so users and contributors can distinguish:

- controls that are structurally enforced;
- settings that only prevent accidental misuse;
- limits that reduce blast radius;
- actions that require an explicit operator decision; and
- protections that only work when verification is actually performed.

HarnessX remains a Roblox Studio-only debugging and testing suite. This document describes the current supported implementation and does not provide bypass instructions.

---

## Classification guide

### Trust levels

| Trust level | Meaning |
|---|---|
| **REAL BOUNDARY** | Enforced by a component separate from the caller, such as Flask validation, the operating-system network stack, filesystem containment, or cryptographic attestation. Bypassing it requires changing or compromising the enforcing component. |
| **DESIGN BOUNDARY** | The system is deliberately built so a capability does not exist or only works through a narrow supported path. It is meaningful in the official implementation, but a source owner could still redesign the software. |
| **HONOR-SYSTEM CHECK** | Enforced in code or configuration controlled by the same operator running HarnessX. Effective against accidents and casual misuse, but not against someone intentionally editing their own copy. |
| **MITIGATION** | Reduces damage, limits volume, preserves recoverability, or detects tampering. It does not necessarily prevent the underlying action. |

### Control types

| Control type | Meaning |
|---|---|
| **HARD BOUNDARY** | No supported toggle exists. Changing it requires source modification and produces an unsupported build. |
| **RUNTIME TOGGLE** | Can be changed while HarnessX is running, normally through a DataModel attribute, plugin control, dashboard action, or authenticated API call. |
| **STARTUP CONFIG** | Read when Flask, Core, the client runner, or the plugin starts. A restart or reload is normally required after changing it. |
| **PER-INSTANCE OPT-OUT** | Applied to a specific Instance or hierarchy through an attribute. |
| **MANUAL ACTION** | Nothing happens until the operator explicitly starts the operation. |
| **BUILD-TIME VERIFICATION** | Applied while generating or verifying an official artifact, rather than while the plugin is running. |

### Reload terminology

- **Flask restart** means stopping and starting `python server/main.py`.
- **Core reload** means restarting the Studio playtest or otherwise rerunning `Core.lua`.
- **Plugin reload** means reloading/restarting the installed Studio plugin.
- **Client reload** means restarting the playtest LocalScript environment.
- **No reload** means the change is observed dynamically.

---

# 1. Execution and bridge boundaries

## Guardrail matrix

| Guardrail | Trust level | Control type | How it is controlled | Reload required? | What it protects against |
|---|---|---|---|---|---|
| `RunService:IsStudio()` | **HONOR-SYSTEM CHECK** | **HARD BOUNDARY** in the supported project | Present as the first line of every Luau entry point | Source modification would be required | Prevents accidental execution outside Studio in the official source tree |
| `HarnessXEnabled` attribute | **HONOR-SYSTEM CHECK** | **RUNTIME TOGGLE / startup gate** | `game:SetAttribute("HarnessXEnabled", true/false)` | Usually yes for a complete stop/start | Prevents HarnessX modules from starting unless explicitly enabled |
| Studio HTTP permission | **HONOR-SYSTEM CHECK** enforced by Roblox | **MANUAL SETTING** | Game Settings → Security → Allow HTTP Requests | Core/plugin reload may be required | Prevents Studio code from contacting the local bridge |
| Loopback-only bridge | **REAL BOUNDARY** | **HARD BOUNDARY** | Flask requires `127.0.0.1` and refuses other hosts | Flask restart after configuration changes | Prevents access from other machines on the network |
| Bridge token | **REAL BOUNDARY**, with same-DataModel caveat | **STARTUP CREDENTIAL** | `config.json`, generated first-run token, or `HARNESSX_BRIDGE_TOKEN` | Flask restart; Studio token attribute must match | Rejects unauthenticated local processes and ordinary browser requests |
| Token length validation | **REAL BOUNDARY** | **HARD VALIDATION** | Enforced by Flask configuration loading | Flask restart | Rejects missing or obviously weak token values |
| Browser-origin rejection | **REAL BOUNDARY** | **HARD BOUNDARY** | Flask rejects requests containing an `Origin` header | Source modification required | Prevents ordinary webpages from calling the loopback service |
| CORS preflight rejection | **REAL BOUNDARY** | **HARD BOUNDARY** | Flask rejects `OPTIONS` requests to `/v1/*` | Source modification required | Prevents browser CORS negotiation from opening the bridge |
| CORS-header stripping | **REAL BOUNDARY** | **HARD BOUNDARY** | Flask removes permissive CORS response headers | Source modification required | Prevents accidental future response-level CORS exposure |
| Maximum request body | **REAL BOUNDARY** | **STARTUP CONFIG** | `bridge.max_body_bytes` | Flask restart | Limits memory and processing pressure from oversized requests |
| Process-memory boundary | **DESIGN BOUNDARY** | **HARD BOUNDARY** | Read endpoint always returns 403; no write endpoint exists | Source redesign required | Prevents arbitrary external process-memory access |

## Important interpretation

The two Luau lines:

```lua
if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end
```

are valuable safety rails, but they are not cryptographic security controls.

A developer who owns and edits their own source can change either line. Their purpose is to make the official HarnessX tree fail closed during ordinary use, not to defeat a motivated person who intentionally creates a different fork.

## `HarnessXEnabled` is not an emergency kill switch

Setting:

```lua
game:SetAttribute("HarnessXEnabled", false)
```

prevents newly loaded HarnessX files from starting. It does not guarantee that every already-running task, connection, plugin callback, or playtest thread immediately terminates.

For a complete shutdown:

1. set the attribute to `false`;
2. stop the playtest;
3. reload the plugin if necessary; and
4. stop Flask when the bridge is no longer needed.

## Bridge-token scope

The token protects the Flask bridge from:

- unrelated local processes;
- unauthenticated scripts outside Studio;
- ordinary browser pages; and
- accidental requests without the expected header.

It does **not** protect HarnessX from code already running inside the same Studio DataModel. Such code may be able to read the `HarnessXBridgeToken` attribute or call HarnessX-owned transport remotes.

Therefore:

> Do not enable HarnessX while running untrusted place code.

---

# 2. Plugin and source-instrumentation guardrails

| Guardrail | Trust level | Control type | How it is controlled | Reload required? | Purpose |
|---|---|---|---|---|---|
| `plugin.enabled` | **HONOR-SYSTEM CHECK** | **STARTUP CONFIG** | `config.json` | Flask restart and plugin reload | Disables plugin startup |
| `auto_rewrite_on_save` | **HONOR-SYSTEM CHECK** | **STARTUP CONFIG** | `config.json` | Plugin reload | Controls whether edit events trigger automatic rewriting |
| Plugin toolbar Toggle | **HONOR-SYSTEM CHECK** | **RUNTIME TOGGLE** | Studio toolbar button | No reload | Enables/disables automatic rewrite-on-save handling |
| Manual Rewrite action | **HONOR-SYSTEM CHECK** | **MANUAL ACTION** | Rewrite button | No reload | Performs an explicit batch rewrite |
| `wrapper_style` | **HONOR-SYSTEM CHECK** | **STARTUP CONFIG** | `"UNC"` or `"RemoteProxy"` in `config.json` | Plugin reload | Selects the generated wrapper syntax |
| Source masking | **MITIGATION** | **HARD-CODED SAFETY** | Built into the rewriter | Source modification required | Avoids rewriting comments and string content |
| Source-directive preservation | **MITIGATION** | **HARD-CODED SAFETY** | Built into header insertion | Source modification required | Keeps directives such as `--!strict` at the top |
| HarnessX package self-exclusion | **DESIGN BOUNDARY** | **HARD-CODED EXCLUSION** | Plugin excludes its own package hierarchy | Source modification required | Stops HarnessX from rewriting itself |
| `HarnessXIgnore` | **HONOR-SYSTEM CHECK** | **PER-INSTANCE OPT-OUT** | Instance attribute | Usually no reload; rescanning may be required | Excludes selected scripts, folders, and remotes |
| Manual `RemoteProxy.wrap()` | **DESIGN BOUNDARY** | **MANUAL / explicit code action** | The caller passes a specific remote | No reload | Avoids global interception |
| RemoteProxy cache | **MITIGATION** | **AUTOMATIC** | Internal weak-key cache | No reload | Avoids duplicate proxies for the same Instance |
| `AutoProxy.wrapFolder()` snapshot | **DESIGN BOUNDARY** | **MANUAL ACTION** | Called explicitly for one folder | Rerun after hierarchy changes | Builds a scoped hierarchy rather than scanning globally |

## Three different “enabled” controls

HarnessX currently has three similarly named controls:

### 1. DataModel `HarnessXEnabled`

```lua
game:SetAttribute("HarnessXEnabled", true)
```

This controls whether HarnessX Luau entry points start.

### 2. `plugin.enabled` in `config.json`

```json
"plugin": {
  "enabled": true
}
```

This controls whether the plugin continues loading after it fetches bridge configuration.

### 3. Plugin toolbar Toggle

This changes the plugin setting used by automatic rewrite-on-save logic. It does **not** stop Core, Flask, RemoteProxy, fuzzing infrastructure, or the entire HarnessX suite.

The README should avoid calling all three simply “HarnessXEnabled” without explaining the scope.

## Per-instance exclusions

Set an exclusion:

```lua
instance:SetAttribute("HarnessXIgnore", true)
```

Remove it:

```lua
instance:SetAttribute("HarnessXIgnore", nil)
```

For plugin scanning, an attribute on a parent folder excludes descendants because the plugin checks the ancestor chain.

For `RemoteProxy.wrap()`, the remote itself is checked. An ignored remote is returned unchanged instead of receiving HarnessX proxy behavior.

`AutoProxy.wrapFolder()` produces a snapshot. After adding, removing, renaming, or changing attributes on remotes, call it again to rebuild the hierarchy.

---

# 3. Runtime modes and profiling controls

| Control | Trust level | Control type | How it is controlled | Persistence | Reload required? |
|---|---|---|---|---|---|
| SUNC `observe` mode | **HONOR-SYSTEM CHECK** | **RUNTIME TOGGLE** | Dashboard or authenticated `/v1/config/update` | In-memory only | No |
| SUNC `mock` mode | **HONOR-SYSTEM CHECK** | **RUNTIME TOGGLE** | Dashboard or API | In-memory only | No |
| SUNC `fuzz` mode | **HONOR-SYSTEM CHECK** | **RUNTIME TOGGLE** | Authenticated API/session flow | In-memory only | No |
| Active profile | **MITIGATION** | **RUNTIME TOGGLE** | Dashboard or `/v1/config/update` | In-memory only | No |
| Default active profile | **MITIGATION** | **STARTUP CONFIG** | `active_profile` in `config.json` | Persistent | Flask restart |
| Profiling enabled | **MITIGATION** | **STARTUP CONFIG** | `profiling.enabled` | Persistent | Flask/Core reload |
| Profiling window | **MITIGATION** | **STARTUP CONFIG** | `profiling.window_seconds` | Persistent | Flask/Core reload |
| Process scanner enabled | **MITIGATION** | **STARTUP CONFIG** | `scanner.enabled` | Persistent | Flask restart |

## Mode behavior

### Observe

- Calls the real RemoteFunction.
- Records target latency.
- Avoids blocking the game call on a synchronous localhost preflight.

### Mock

- May replace the real return value with configured mock data.
- Intentionally changes behavior.
- Should only be enabled while the operator expects simulated results.

### Fuzz

- Supports controlled randomized arguments.
- Intentionally changes call inputs.
- Is bounded by server-side fuzz limits.

Runtime changes are not written back to `config.json`. Restarting Flask restores the configured defaults.

---

# 4. Fuzzing guardrails

| Guardrail | Trust level | Control type | How it is controlled | Reload required? | Effect |
|---|---|---|---|---|---|
| Explicit Start | **HONOR-SYSTEM CHECK** | **MANUAL ACTION** | Dashboard or authenticated API | No | Prevents accidental automatic fuzzing |
| Explicit Stop | **HONOR-SYSTEM CHECK** | **MANUAL ACTION** | Dashboard/API | No | Requests session termination |
| `max_rate` | **REAL BOUNDARY** | **STARTUP CONFIG with server validation** | `fuzzer.max_rate` | Flask restart | Caps calls per second |
| Minimum rate | **REAL BOUNDARY** | **HARD VALIDATION** | Flask | Source modification required | Rejects zero/negative rates |
| Maximum duration | **REAL BOUNDARY** | **HARD VALIDATION** | Flask constant | Source modification required | Caps session length |
| Minimum duration | **REAL BOUNDARY** | **HARD VALIDATION** | Flask | Source modification required | Rejects meaningless/invalid durations |
| Target class validation | **REAL BOUNDARY** | **HARD VALIDATION** | Flask accepts only RemoteEvent/RemoteFunction | Source modification required | Rejects unsupported target classes |
| Target-segment validation | **REAL BOUNDARY** | **HARD VALIDATION** | Flask | Source modification required | Requires structured target identity |
| Schema validation | **REAL BOUNDARY** | **HARD VALIDATION** | Flask and client materializer | Source modification required | Rejects malformed requests |
| Session-history cap | **REAL BOUNDARY** | **STARTUP CONFIG** | `fuzzer.max_history_sessions` | Flask restart | Bounds retained completed-session state |
| Studio client execution | **DESIGN BOUNDARY** | **HARD BOUNDARY** in supported architecture | Fuzzer LocalScript performs calls | Source redesign required | Keeps execution inside Studio playtests |
| `HarnessXIgnore` target exclusion | **HONOR-SYSTEM CHECK** | **PER-INSTANCE OPT-OUT** | Attribute | Refresh remote list | Avoids selecting excluded remotes |

## Authorization gap

HarnessX validates:

- rate;
- duration;
- target shape;
- target class;
- argument schema; and
- session lifecycle.

It does **not** independently prove that the operator owns or is authorized to test the currently open place.

The official expectation is:

> Only use fuzzing against projects and environments you own or are explicitly authorized to test.

A typed confirmation, place-identity display, and audit logging would reduce accidental misuse. However, a client-reported place ID or creator ID is evidence, not independent proof, unless the bridge validates it through a trusted authenticated source.

---

# 5. Queue, traffic, and runtime-resilience guardrails

| Guardrail | Trust level | Control type | How it is controlled | Reload required? | Purpose |
|---|---|---|---|---|---|
| `max_pending_events` | **REAL BOUNDARY** inside Core | **STARTUP CONFIG** | `runtime.max_pending_events` | Flask/Core reload | Bounds queued traffic |
| Drop-oldest behavior | **MITIGATION** | **HARD-CODED** | Core queue implementation | Source modification required | Preserves recent events under pressure |
| Per-player event rate | **REAL BOUNDARY** inside Core | **STARTUP CONFIG** | `runtime.max_events_per_player_per_second` | Flask/Core reload | Limits one playtest client |
| Maximum event bytes | **REAL BOUNDARY** inside Core | **STARTUP CONFIG** | `runtime.max_event_bytes` | Flask/Core reload | Rejects oversized records |
| Maximum batch retries | **MITIGATION** | **STARTUP CONFIG** | `runtime.max_batch_retries` | Flask/Core reload | Prevents infinite retry loops |
| Exponential backoff | **MITIGATION** | **HARD-CODED** | Core | Source modification required | Reduces pressure during bridge failures |
| Serialization depth | **MITIGATION** | **HARD-CODED** | Luau serializer limits | Source modification required | Avoids runaway nested data |
| Table-item cap | **MITIGATION** | **HARD-CODED** | Luau serializer limits | Source modification required | Bounds individual payload expansion |
| Dropped/failed counters | **MITIGATION** | **AUTOMATIC OBSERVABILITY** | Runtime status | No | Makes overload and failures visible |

These limits protect reliability and resource usage. They do not prove that the submitted trace data is truthful; a client inside the DataModel can still construct misleading messages.

---

# 6. Backup guardrails

| Guardrail | Trust level | Control type | How it is controlled | Reload required? | Effect |
|---|---|---|---|---|---|
| Manual Backup button | **HONOR-SYSTEM CHECK** | **MANUAL ACTION** | Plugin UI | No | Prevents automatic source collection |
| Relative output directory | **REAL BOUNDARY** | **STARTUP CONFIG with validation** | `backup.output_dir` | Flask restart | Keeps backups inside the project |
| Absolute-path rejection | **REAL BOUNDARY** | **HARD VALIDATION** | Flask | Source modification required | Prevents arbitrary filesystem destinations |
| `..` traversal rejection | **REAL BOUNDARY** | **HARD VALIDATION** | Flask | Source modification required | Prevents escaping the project root |
| Path sanitization | **REAL BOUNDARY** | **HARD-CODED** | Flask | Source modification required | Removes unsafe path characters |
| Collision suffixes | **MITIGATION** | **AUTOMATIC** | Flask | No | Prevents silent overwrites |
| Maximum 5,000 entries | **REAL BOUNDARY** | **HARD VALIDATION** | Flask | Source modification required | Bounds file count per request |
| `max_backups` | **REAL BOUNDARY** | **STARTUP CONFIG** | `backup.max_backups` | Flask restart | Bounds retained backup folders |
| Request body limit | **REAL BOUNDARY** | **STARTUP CONFIG** | `bridge.max_body_bytes` | Flask restart | Bounds total backup payload size |

## Authorization gap

The filesystem handling is strongly constrained, but HarnessX does not independently prove that the operator owns every script exposed in the current DataModel.

Only back up source from projects you own or are authorized to access.

A future confirmation flow could display:

- place ID;
- game ID;
- creator identity, when available;
- script count;
- intended backup destination; and
- operator confirmation.

That would reduce accidental misuse, but it should not be described as cryptographic authorization unless independently verified.

---

# 7. Provenance and official-build verification

| Guardrail | Trust level | Control type | How it is controlled | Reload required? | Meaning |
|---|---|---|---|---|---|
| Checksum banner | **MITIGATION** | **BUILD-TIME VERIFICATION** | Added by `tools/build_plugin.py` | Not applicable | Identifies claimed build metadata |
| Manifest | **MITIGATION** | **BUILD-TIME VERIFICATION** | Generated beside the artifact | Not applicable | Records source/artifact digest and size |
| `SHA256SUMS` | **MITIGATION** | **BUILD-TIME VERIFICATION** | Generated automatically | Not applicable | Detects artifact/manifest modification |
| Local verifier | **MITIGATION** | **MANUAL ACTION / CI** | `tools/verify_build.py` | Not applicable | Rejects modified or inconsistent files |
| GitHub attestation | **REAL BOUNDARY** for origin | **BUILD-TIME VERIFICATION** | Official release workflow | Not applicable | Proves a digest came from the official repository workflow |
| Runtime provenance enforcement | Not currently implemented | — | — | — | The plugin does not currently refuse to run based on attestation |

## What provenance proves

A valid GitHub attestation proves that:

- a specific file digest;
- was produced by a GitHub Actions workflow;
- associated with `n4thyan/HarnessX`.

It does not prove that:

- the plugin is bug-free;
- the installed Studio copy still has identical bytes;
- the operator did not edit the plugin after verification;
- a different unverified copy cannot run; or
- redistribution is prohibited.

HarnessX is MIT-licensed. Provenance distinguishes official and modified builds; it is not anti-copy DRM.

## Verification commands

Local integrity:

```bash
python tools/verify_build.py HarnessXPlugin.manifest.json
```

Official GitHub origin:

```bash
gh attestation verify HarnessXPlugin.lua -R n4thyan/HarnessX
```

The banner alone must never be treated as proof.

---

# 8. Summary by control type

## Hard boundaries

These have no supported toggle:

- Studio-only guard in official Luau entry points;
- loopback-only Flask binding;
- browser-origin and CORS-preflight rejection;
- CORS-header stripping;
- no process-memory write endpoint;
- disabled process-memory read endpoint;
- server-side input validation;
- filesystem containment; and
- supported Studio-client fuzz execution architecture.

Changing these requires source modification and produces a separate unsupported build.

## Runtime toggles

These can change without restarting Flask:

- SUNC mode;
- active performance profile;
- DataModel `HarnessXEnabled`, with the shutdown caveat;
- plugin automatic-rewrite Toggle; and
- manual fuzz start/stop operations.

## Startup configuration

These normally require restart or reload:

- bridge port and request-size limit;
- default active profile;
- scanner settings;
- plugin enabled state;
- auto-rewrite-on-save;
- wrapper style;
- fuzzer defaults and caps;
- backup location and retention;
- profiling settings; and
- runtime queue/rate/retry limits.

## Per-instance opt-outs

- `HarnessXIgnore`

This is useful for scoping and noise reduction. It is not a security boundary because scripts with DataModel write access can change it.

## Manual actions

- Rewrite scripts;
- inject trace;
- start fuzzing;
- stop fuzzing;
- create backups;
- wrap a specific remote;
- wrap a specific folder; and
- verify a downloaded build.

## Build-time verification

- Generated provenance banner;
- manifest;
- checksum file;
- local verifier;
- CI reproducibility tests; and
- GitHub artifact attestation.

---

# 9. Remaining trust gaps

## 9.1 Same-DataModel trust

HarnessX cannot treat another script inside the same Studio DataModel as an untrusted external party while also exposing attributes and transport remotes to that DataModel.

The token is therefore not a secret from all Studio code.

## 9.2 Operator authorization

HarnessX does not independently establish that the operator owns or is authorized to test the current place.

The suite relies on lawful, authorized use.

## 9.3 Self-modifiable source

Open-source guard code can be edited by someone who controls their own copy. This is expected. Official builds provide safer defaults and verifiable provenance, not immutable client-side enforcement.

## 9.4 Runtime provenance

Official artifact verification currently occurs outside Studio. HarnessX does not automatically verify a GitHub attestation when the plugin loads.

## 9.5 Client-reported identity

Any future place-identity confirmation sent from Luau to Flask should be treated as a claim unless Flask verifies it through an independently trusted authenticated service.

---

# 10. Recommendations ranked by impact

1. **Add a clear preflight confirmation before fuzzing and backups.** Display place identity, target, rate/duration or script count, and require explicit confirmation.

2. **Persist a local audit log for sensitive actions.** Record timestamp, place ID, target, configuration, result, and build identity for fuzzing, rewriting, and backups.

3. **Separate “disable new startup” from “stop active runtime.”** A dedicated shutdown path could disconnect HarnessX-owned connections and stop background tasks cleanly.

4. **Make control scope visible in the plugin UI.** Clearly distinguish:
   - suite enabled;
   - plugin enabled;
   - automatic rewrite enabled;
   - SUNC mode;
   - active profile; and
   - provenance status.

5. **Add optional runtime build-identity reporting.** The plugin could display its build ID and source hash. This would improve visibility, although it would remain self-reported unless checked against the external manifest or attestation.

6. **Keep authorization checks server-side where the server has independent evidence.** Continue enforcing rate, duration, filesystem, payload, and schema limits in Flask rather than relying only on UI validation.

7. **Document the token scope prominently.** It protects the loopback HTTP boundary, not against code already executing inside the same DataModel.

8. **Retain no-CORS regression tests.** Treat any future `flask-cors` or wildcard-origin proposal as a security-sensitive change.

---

# 11. Operator checklist

Before enabling HarnessX:

- Confirm the place is yours or you have explicit authorization.
- Confirm Flask is bound to `127.0.0.1`.
- Confirm the bridge token is not the committed placeholder.
- Set the matching Studio token attribute.
- Avoid running untrusted place code.
- Leave automatic rewriting disabled unless intentionally required.
- Mark excluded scripts/remotes with `HarnessXIgnore`.
- Confirm SUNC is in the expected mode.
- Confirm fuzz rate and duration before starting.
- Confirm backup destination and script count.
- Use an official attested artifact when provenance matters.

After use:

- Stop active fuzz sessions.
- Stop the playtest.
- Set `HarnessXEnabled` to `false`.
- Reload or disable the plugin when appropriate.
- Stop Flask.
- Review logs, backups, and dropped-event counters.
- Remove the token attribute from projects where it should not persist.

---

*This document describes the supported HarnessX trust boundaries at the time of writing. It intentionally explains control scope and enforcement strength without describing bypass procedures.*

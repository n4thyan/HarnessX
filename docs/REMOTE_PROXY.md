# HarnessX RemoteProxy

`RemoteProxy.lua` provides a manual, opt-in table wrapper for an individual `RemoteEvent` or `RemoteFunction`.

It does **not** modify Roblox Instance metatables, override engine methods, scan the DataModel, or intercept remotes that the caller did not explicitly wrap.

## Runtime safety

HarnessX remains Studio-only. Runtime modules begin with both checks:

```lua
if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end
```

`HarnessXEnabled` is an additional opt-in switch inside Studio; it does not bypass the Studio guard.

Enable it before requiring HarnessX runtime modules:

```lua
game:SetAttribute("HarnessXEnabled", true)
```

## Installation

Create this ModuleScript:

```text
ReplicatedStorage
└── HarnessX
    └── RemoteProxy
```

Paste `roblox/RemoteProxy.lua` into it.

The existing runtime layout must also contain:

```text
ReplicatedStorage.HarnessX.UNC
ReplicatedStorage.HarnessX.SUNC
ReplicatedStorage.HarnessX.Transport.DebugEvent
ReplicatedStorage.HarnessX.Transport.DebugFunction
```

## RemoteEvent example

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HarnessX = ReplicatedStorage:WaitForChild("HarnessX")
local RemoteProxy = require(HarnessX:WaitForChild("RemoteProxy"))

local purchaseRemote = ReplicatedStorage.Remotes.Purchase
local purchase = RemoteProxy.wrap(purchaseRemote)

purchase:FireServer("Sword", 1)
```

The call is delegated to `UNC.FireServer()`, so it uses the existing serializer, `DebugEvent`, batching path, and dashboard traffic feed.

## RemoteFunction example

```lua
local inventoryRemote = ReplicatedStorage.Remotes.GetInventory
local inventory = RemoteProxy.wrap(inventoryRemote)

local success, result = inventory:InvokeServer()
```

The call is delegated to `SUNC.InvokeServer()`, including the existing observe/mock preflight behavior and return-value logging.

## Forwarded members

Other properties and methods are forwarded to the original Instance:

```lua
print(purchase.Name)
print(purchase.Parent)
print(purchase:GetFullName())
```

The proxy itself is a table. Use `.Original` when another Roblox API requires the real Instance:

```lua
local originalRemote = purchase.Original
```

## Ignored remotes

When the selected remote has this Boolean attribute set to `true`:

```text
HarnessXIgnore
```

`RemoteProxy.wrap()` returns the original Instance unchanged.

## AutoProxy

`roblox/AutoProxy.lua` is included in the repository. It scans a selected folder and its descendants, builds a matching Luau table hierarchy, and wraps eligible `RemoteEvent` and `RemoteFunction` leaves through the existing `RemoteProxy` module.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HarnessX = ReplicatedStorage:WaitForChild("HarnessX")
local AutoProxy = require(HarnessX:WaitForChild("AutoProxy"))

local remotes = AutoProxy.wrapFolder(
    ReplicatedStorage:WaitForChild("Remotes")
)

remotes.Purchase:FireServer("Sword", 1)
local inventory = remotes.Api.GetInventory:InvokeServer()
```

`AutoProxy.wrapFolder()` respects `HarnessXIgnore` on the root, ancestors, and remotes. It calls `RemoteProxy.wrap()`, so repeated wrapping reuses the existing RemoteProxy cache. The hierarchy is a snapshot of remotes present when called; call it again after changing the folder structure.

## Studio-only execution

HarnessX remains Studio-only.

The `HarnessXEnabled` attribute is an additional opt-in gate inside Studio. It does not bypass `RunService:IsStudio()`.

Running HarnessX in a published live client is not supported out of the box. To run it in a live client, you would need to maintain a separate unsupported fork with the Studio guards manually removed from the Luau files. This configuration is not tested, recommended, or supported by the HarnessX project.

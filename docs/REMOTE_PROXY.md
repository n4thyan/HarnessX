# HarnessX RemoteProxy

`RemoteProxy.lua` provides a manual, opt-in table wrapper for an individual `RemoteEvent` or `RemoteFunction`.

It does **not** modify Roblox Instance metatables, override engine methods, scan the DataModel, or intercept remotes that the caller did not explicitly wrap.

## Branch safety state

The `global-hooks` branch remains Studio-only. Runtime modules begin with both checks:

```lua
if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end
```

`HarnessXEnabled` is therefore an additional opt-in switch inside Studio; it does not bypass the Studio guard.

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

## AutoProxy status

`AutoProxy.lua` has not yet been added. Its requested specification was cut off after:

```lua
AutoProxy.wrapFolder(folder: Instance): table
```

The remaining behavior, return-table shape, descendant tracking rules, cleanup API, and handling of future remotes need to be specified before implementation.

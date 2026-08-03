if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

--[[
	HarnessX RemoteProxy

	Manual, opt-in table proxy for one RemoteEvent or RemoteFunction selected by
	the caller. This module does not alter Instance metatables, replace Roblox
	engine methods, scan the DataModel, or intercept unrelated remotes.

	Calls are delegated to the existing UNC/SUNC wrappers, so RemoteProxy uses
	the same serializer, DebugEvent transport, SUNC preflight/mock behavior, and
	dashboard traffic path as source-instrumented calls.

	Example:

		local HarnessX = game:GetService("ReplicatedStorage"):WaitForChild("HarnessX")
		local RemoteProxy = require(HarnessX:WaitForChild("RemoteProxy"))

		local purchase = RemoteProxy.wrap(HarnessX.Parent.Remotes.Purchase)
		purchase:FireServer("Sword", 1)

	The returned value is a table, not an Instance. Use proxy.Original whenever
	an API explicitly requires the underlying RemoteEvent or RemoteFunction.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local harnessFolder = ReplicatedStorage:WaitForChild("HarnessX")
local UNC = require(harnessFolder:WaitForChild("UNC"))
local SUNC = require(harnessFolder:WaitForChild("SUNC"))

local RemoteProxy = {}

type SupportedRemote = RemoteEvent | RemoteFunction

type Proxy = {
	Original: SupportedRemote,
	FireServer: ((self: Proxy, ...any) -> ())?,
	InvokeServer: ((self: Proxy, ...any) -> ...any)?,
}

-- Weak keys avoid retaining remotes solely because they were wrapped once.
local proxyCache: {[Instance]: Proxy} = setmetatable({}, {
	__mode = "k",
}) :: any

local function assertSupported(remote: any): SupportedRemote
	assert(
		typeof(remote) == "Instance",
		"RemoteProxy.wrap expected a Roblox Instance"
	)

	assert(
		remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction"),
		"RemoteProxy.wrap expected a RemoteEvent or RemoteFunction"
	)

	return remote :: SupportedRemote
end

local function createProxy(remote: SupportedRemote): Proxy
	local proxy = {} :: any

	local function fireServer(first: any, ...: any)
		assert(
			remote:IsA("RemoteEvent"),
			"FireServer is only available for RemoteEvent proxies"
		)

		-- Support normal colon syntax and explicit dot syntax:
		-- proxy:FireServer(value)
		-- proxy.FireServer(value)
		if first == proxy then
			UNC.FireServer(remote :: RemoteEvent, ...)
		else
			UNC.FireServer(remote :: RemoteEvent, first, ...)
		end
	end

	local function invokeServer(first: any, ...: any): ...any
		assert(
			remote:IsA("RemoteFunction"),
			"InvokeServer is only available for RemoteFunction proxies"
		)

		if first == proxy then
			return SUNC.InvokeServer(remote :: RemoteFunction, ...)
		end

		return SUNC.InvokeServer(remote :: RemoteFunction, first, ...)
	end

	setmetatable(proxy, {
		__index = function(_self, key)
			if key == "Original" then
				return remote
			end

			if key == "FireServer" and remote:IsA("RemoteEvent") then
				return fireServer
			end

			if key == "InvokeServer" and remote:IsA("RemoteFunction") then
				return invokeServer
			end

			local success, member = pcall(function()
				return (remote :: any)[key]
			end)

			if not success then
				error(member, 2)
			end

			if typeof(member) == "function" then
				-- Preserve colon-style Instance methods through the proxy, for
				-- example proxy:GetFullName() and proxy:IsDescendantOf(folder).
				return function(first: any, ...: any): ...any
					if first == proxy then
						return member(remote, ...)
					end

					return member(remote, first, ...)
				end
			end

			return member
		end,

		__newindex = function(_self, key, value)
			-- Property assignments are intentionally forwarded to the original
			-- Instance and remain subject to Roblox's normal validation.
			(remote :: any)[key] = value
		end,

		__tostring = function()
			return tostring(remote)
		end,
	})

	return proxy
end

function RemoteProxy.wrap(candidate: RemoteEvent | RemoteFunction): any
	local remote = assertSupported(candidate)

	-- Respect the explicit per-Instance exclusion. Returning the original keeps
	-- ordinary call syntax valid while adding no HarnessX proxy behavior.
	if remote:GetAttribute("HarnessXIgnore") == true then
		return remote
	end

	local cached = proxyCache[remote]
	if cached ~= nil then
		return cached
	end

	local proxy = createProxy(remote)
	proxyCache[remote] = proxy

	return proxy
end

return table.freeze(RemoteProxy)

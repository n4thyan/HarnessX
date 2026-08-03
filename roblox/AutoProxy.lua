if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then
	-- Preserve the requested no-op behavior while HarnessX is disabled.
	return table.freeze({
		wrapFolder = function(folder: Instance): Instance
			assert(typeof(folder) == "Instance", "AutoProxy.wrapFolder expected an Instance")
			return folder
		end,
	})
end

--[[
	HarnessX AutoProxy

	Builds a normal Luau table that mirrors the hierarchy beneath a selected
	folder. RemoteEvent and RemoteFunction leaves are manual RemoteProxy wrappers.

	This module does not alter Instance metatables, replace engine methods, or
	intercept remotes globally. It simply saves repeated RemoteProxy.wrap() calls.

	Example:

		local HarnessX = game:GetService("ReplicatedStorage"):WaitForChild("HarnessX")
		local AutoProxy = require(HarnessX:WaitForChild("AutoProxy"))

		local remotes = AutoProxy.wrapFolder(
			game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
		)

		remotes.Purchase:FireServer("Sword", 1)
		local inventory = remotes.Api.GetInventory:InvokeServer()

	Only remotes present when wrapFolder() is called are included. Call it again
	to rebuild the hierarchy after adding or removing remotes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local harnessFolder = ReplicatedStorage:WaitForChild("HarnessX")
local RemoteProxy = require(harnessFolder:WaitForChild("RemoteProxy"))

local AutoProxy = {}

local function isSupportedRemote(instance: Instance): boolean
	return instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction")
end

local function isIgnored(instance: Instance, root: Instance): boolean
	local current: Instance? = instance

	while current ~= nil do
		if current:GetAttribute("HarnessXIgnore") == true then
			return true
		end

		if current == root then
			break
		end

		current = current.Parent
	end

	return false
end

local function relativeAncestors(remote: Instance, root: Instance): {Instance}
	local result = {}
	local current = remote.Parent

	while current ~= nil and current ~= root do
		table.insert(result, 1, current)
		current = current.Parent
	end

	return result
end

local function ensureHierarchyNode(parentNode: {[any]: any}, instance: Instance): {[any]: any}
	local existing = parentNode[instance.Name]

	if existing == nil then
		local node = {
			__instance = instance,
		}
		parentNode[instance.Name] = node
		return node
	end

	if typeof(existing) == "table" and existing.Original == nil then
		return existing
	end

	-- Roblox permits duplicate sibling names. The first value keeps the direct
	-- name lookup; duplicates remain available through a reserved list.
	local duplicates = parentNode.__duplicates
	if typeof(duplicates) ~= "table" then
		duplicates = {}
		parentNode.__duplicates = duplicates
	end

	local duplicateNode = {
		__instance = instance,
	}
	table.insert(duplicates, {
		name = instance.Name,
		value = duplicateNode,
	})

	return duplicateNode
end

local function assignRemote(parentNode: {[any]: any}, remote: RemoteEvent | RemoteFunction)
	local proxy = RemoteProxy.wrap(remote)
	local existing = parentNode[remote.Name]

	if existing == nil then
		parentNode[remote.Name] = proxy
		return
	end

	local duplicates = parentNode.__duplicates
	if typeof(duplicates) ~= "table" then
		duplicates = {}
		parentNode.__duplicates = duplicates
	end

	table.insert(duplicates, {
		name = remote.Name,
		value = proxy,
	})
end

function AutoProxy.wrapFolder(folder: Instance): any
	assert(typeof(folder) == "Instance", "AutoProxy.wrapFolder expected an Instance")

	if game:GetAttribute("HarnessXEnabled") ~= true then
		return folder
	end

	local hierarchy: {[any]: any} = {
		__instance = folder,
	}

	if folder:GetAttribute("HarnessXIgnore") == true then
		return hierarchy
	end

	local remotes = {}

	for _, descendant in folder:GetDescendants() do
		if isSupportedRemote(descendant) and not isIgnored(descendant, folder) then
			table.insert(remotes, descendant)
		end
	end

	table.sort(remotes, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	for _, remote in remotes do
		local node = hierarchy

		for _, ancestor in relativeAncestors(remote, folder) do
			node = ensureHierarchyNode(node, ancestor)
		end

		assignRemote(node, remote :: any)
	end

	return hierarchy
end

return table.freeze(AutoProxy)

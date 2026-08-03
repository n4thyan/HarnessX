if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packageFolder = ReplicatedStorage:WaitForChild("HarnessX")
local AutoProxy = require(packageFolder:WaitForChild("AutoProxy"))
local Fuzzer = require(packageFolder:WaitForChild("Fuzzer"))

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if remotesFolder ~= nil then
	local wrapOk, wrapped = pcall(AutoProxy.wrapFolder, remotesFolder)
	if wrapOk then
		_G.HarnessXRemotes = wrapped
		print("HarnessX client quick start: _G.HarnessXRemotes is ready.")
	else
		warn("HarnessX client quick start failed: " .. tostring(wrapped))
	end
end

Fuzzer.Run()

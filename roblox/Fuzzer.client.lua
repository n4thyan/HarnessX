if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fuzzer = require(
	ReplicatedStorage:WaitForChild("HarnessX"):WaitForChild("Fuzzer")
)

Fuzzer.Run()

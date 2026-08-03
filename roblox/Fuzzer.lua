if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

--[[
	Studio-only remote fuzzer runtime.

	The dashboard plugin is an editor tool, not a network client. This module is
	required by a LocalScript during playtests so FireServer/InvokeServer execute
	in the supported client context. Sessions are claimed through Core.lua and
	all attempts are bounded by the bridge configuration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local packageFolder = ReplicatedStorage:WaitForChild("HarnessX")
local transportFolder = packageFolder:WaitForChild("Transport")
local fuzzControl = transportFolder:WaitForChild("FuzzControl") :: RemoteFunction
local fuzzReport = transportFolder:WaitForChild("FuzzReport") :: RemoteEvent
local UNC = require(packageFolder:WaitForChild("UNC"))
local SUNC = require(packageFolder:WaitForChild("SUNC"))

local Fuzzer = {}

local running = false
local activeSessionId: string? = nil

local function resolveSegments(segments: any): Instance?
	if typeof(segments) ~= "table" then
		return nil
	end

	local current: Instance = game

	for index = 1, #segments do
		local segment = tostring(segments[index])

		if index == 1 and segment == "game" then
			continue
		end

		if current == game then
			local serviceOk, service = pcall(function()
				return game:GetService(segment)
			end)

			if serviceOk then
				current = service
				continue
			end
		end

		local child = current:FindFirstChild(segment)
		if child == nil then
			return nil
		end

		current = child
	end

	return current
end

local function report(sessionId: string, payload: {[string]: any})
	payload.sessionId = sessionId
	payload.clientTime = DateTime.now().UnixTimestampMillis

	local ok, reportError = pcall(function()
		fuzzReport:FireServer(payload)
	end)

	if not ok then
		warn("HarnessX fuzz report failed: " .. tostring(reportError))
	end
end

local function sessionStillRunning(sessionId: string): boolean
	local ok, response = pcall(function()
		return fuzzControl:InvokeServer("status", sessionId)
	end)

	if not ok or typeof(response) ~= "table" then
		return true
	end

	local session = response.session
	if typeof(session) ~= "table" then
		return false
	end

	return session.status == "running" or session.status == "queued"
end

local function runSession(session: {[string]: any})
	local sessionId = tostring(session.id)
	local target = resolveSegments(session.targetSegments)
	local targetClass = tostring(session.targetClass or "")
	local rate = math.clamp(tonumber(session.rate) or 1, 1, 100)
	local duration = math.max(tonumber(session.duration) or 1, 0.1)
	local template = session.argTypes

	if target == nil then
		report(sessionId, {
			phase = "session_error",
			error = "Target remote could not be resolved",
			target = session.target,
		})
		return
	end

	if target:GetAttribute("HarnessXIgnore") == true then
		report(sessionId, {
			phase = "session_error",
			error = "Target remote is excluded",
			target = target:GetFullName(),
		})
		return
	end

	if targetClass ~= "" and target.ClassName ~= targetClass then
		report(sessionId, {
			phase = "session_error",
			error = string.format(
				"Target class changed from %s to %s",
				targetClass,
				target.ClassName
			),
			target = target:GetFullName(),
		})
		return
	end

	if not target:IsA("RemoteEvent") and not target:IsA("RemoteFunction") then
		report(sessionId, {
			phase = "session_error",
			error = "Target is not a RemoteEvent or RemoteFunction",
			target = target:GetFullName(),
		})
		return
	end

	report(sessionId, {
		phase = "session_started",
		target = target:GetFullName(),
		targetClass = target.ClassName,
		rate = rate,
		duration = duration,
	})

	local interval = 1 / rate
	local deadline = os.clock() + duration
	local attempt = 0
	local lastControlCheck = 0

	while os.clock() < deadline do
		attempt += 1
		local arguments = UNC.BuildArguments(template)
		local startedAt = os.clock()

		local callOk, callError = pcall(function()
			if target:IsA("RemoteFunction") then
				SUNC.InvokeServer(
					target,
					table.unpack(arguments, 1, arguments.n)
				)
			else
				UNC.FireServer(
					target,
					table.unpack(arguments, 1, arguments.n)
				)
			end
		end)

		local latencyMs = math.floor((os.clock() - startedAt) * 1000)

		report(sessionId, {
			phase = if callOk then "attempt_ok" else "attempt_error",
			attempt = attempt,
			target = target:GetFullName(),
			targetClass = target.ClassName,
			latencyMs = latencyMs,
			error = if callOk then nil else tostring(callError),
			arguments = arguments,
		})

		if os.clock() - lastControlCheck >= 1 then
			lastControlCheck = os.clock()

			if not sessionStillRunning(sessionId) then
				break
			end
		end

		local elapsed = os.clock() - startedAt
		local remaining = interval - elapsed

		if remaining > 0 then
			task.wait(remaining)
		else
			task.wait()
		end
	end

	report(sessionId, {
		phase = "session_finished",
		attempt = attempt,
		target = target:GetFullName(),
	})
end

function Fuzzer.Run()
	if running then
		return
	end

	running = true

	task.spawn(function()
		while running do
			if activeSessionId == nil then
				local claimOk, response = pcall(function()
					return fuzzControl:InvokeServer("claim")
				end)

				if claimOk
					and typeof(response) == "table"
					and typeof(response.session) == "table"
				then
					local session = response.session
					activeSessionId = tostring(session.id)

					local runOk, runError = pcall(runSession, session)

					if not runOk then
						report(activeSessionId, {
							phase = "session_error",
							error = tostring(runError),
							target = session.target,
						})
					end

					activeSessionId = nil
				end
			end

			task.wait(0.5)
		end
	end)
end

function Fuzzer.Stop()
	running = false
	activeSessionId = nil
end

return table.freeze(Fuzzer)

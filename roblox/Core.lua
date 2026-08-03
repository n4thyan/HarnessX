if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

--[[
	Studio-only network, diagnostics, profiling, fuzz coordination, and
	cooperative stack-inspection loader.

	This file uses supported Roblox/Luau APIs only. It does not override engine
	methods and does not interact with process memory.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BRIDGE_URL = "http://127.0.0.1:8765"
local BRIDGE_TOKEN = "change-this-local-token-please"
local MAX_DEPTH = 6
local MAX_TABLE_ITEMS = 128
local MAX_STACK_FRAMES = 64
local MAX_RECENT_CALLS_PER_SOURCE = 20

if not HttpService.HttpEnabled then
	warn("HarnessX stopped: enable Game Settings > Security > Allow HTTP Requests.")
	return nil
end

local packageFolder = ReplicatedStorage:WaitForChild("HarnessX")
local Encoder = require(packageFolder:WaitForChild("Encoder"))

local function ensureChild(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)

	if existing ~= nil then
		assert(existing.ClassName == className, `{existing:GetFullName()} has the wrong class`)
		return existing
	end

	local created = Instance.new(className)
	created.Name = name
	created:SetAttribute("HarnessXIgnore", true)
	created.Parent = parent
	return created
end

local transportFolder = ensureChild(packageFolder, "Folder", "Transport") :: Folder
transportFolder:SetAttribute("HarnessXIgnore", true)

local debugEvent = ensureChild(transportFolder, "RemoteEvent", "DebugEvent") :: RemoteEvent
local debugFunction = ensureChild(transportFolder, "RemoteFunction", "DebugFunction") :: RemoteFunction
local fuzzControl = ensureChild(transportFolder, "RemoteFunction", "FuzzControl") :: RemoteFunction
local fuzzReport = ensureChild(transportFolder, "RemoteEvent", "FuzzReport") :: RemoteEvent

local getInstanceCounts = ensureChild(
	transportFolder,
	"BindableFunction",
	"GetInstanceCounts"
) :: BindableFunction

local getGcStats = ensureChild(
	transportFolder,
	"BindableFunction",
	"GetGcStats"
) :: BindableFunction

local getConnectionCounts = ensureChild(
	transportFolder,
	"BindableFunction",
	"GetConnectionCounts"
) :: BindableFunction

local getScriptStack = ensureChild(
	transportFolder,
	"BindableFunction",
	"GetScriptStack"
) :: BindableFunction

local getPerformanceStats = ensureChild(
	transportFolder,
	"BindableFunction",
	"GetPerformanceStats"
) :: BindableFunction

local function httpRequest(path: string, method: string, body: string?): (boolean, any)
	local options: {[string]: any} = {
		Url = BRIDGE_URL .. path,
		Method = method,
		Headers = {
			["Content-Type"] = "application/json",
			["X-Debug-Token"] = BRIDGE_TOKEN,
		},
	}

	if body ~= nil then
		options.Body = body
	end

	local requestOk, response = pcall(function()
		return HttpService:RequestAsync(options)
	end)

	if not requestOk then
		return false, tostring(response)
	end

	if not response.Success then
		return false, string.format(
			"HTTP %s %s: %s",
			tostring(response.StatusCode),
			tostring(response.StatusMessage),
			tostring(response.Body)
		)
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)

	if not decodeOk then
		return false, "Bridge returned invalid JSON"
	end

	return true, decoded
end

local function requestJson(path: string, method: string, value: any): (boolean, any)
	local body = if value == nil then nil else HttpService:JSONEncode(value)
	return httpRequest(path, method, body)
end

local configOk, publicConfig = httpRequest("/v1/config", "GET", nil)

if not configOk then
	warn("HarnessX stopped: " .. tostring(publicConfig))
	return nil
end

local runtimeProfile = publicConfig.profile
local runtimeProfileName = tostring(publicConfig.active_profile)
local profilingConfig = if typeof(publicConfig.profiling) == "table"
	then publicConfig.profiling
	else {
		enabled = true,
		window_seconds = 60,
	}

assert(typeof(runtimeProfile) == "table", "Bridge profile is missing")
assert(typeof(runtimeProfile.scan_interval_ms) == "number", "Invalid scan_interval_ms")
assert(typeof(runtimeProfile.batch_size) == "number", "Invalid batch_size")
assert(typeof(runtimeProfile.encoder_rounds) == "number", "Invalid encoder_rounds")

local function serialize(value: any, depth: number?, seen: {[any]: boolean}?): any
	local currentDepth = depth or 0
	local visited = seen or {}

	if currentDepth > MAX_DEPTH then
		return "<max-depth>"
	end

	local valueType = typeof(value)

	if value == nil
		or valueType == "boolean"
		or valueType == "number"
		or valueType == "string"
	then
		return value
	end

	if valueType == "Instance" then
		local instance = value :: Instance
		local parent = instance.Parent

		return {
			__type = "Instance",
			name = instance.Name,
			path = instance:GetFullName(),
			ClassName = instance.ClassName,
			Parent = if parent ~= nil
				then {
					name = parent.Name,
					path = parent:GetFullName(),
					ClassName = parent.ClassName,
				}
				else nil,
		}
	end

	if valueType == "Vector2" then
		return { __type = "Vector2", x = value.X, y = value.Y }
	end

	if valueType == "Vector3" then
		return { __type = "Vector3", x = value.X, y = value.Y, z = value.Z }
	end

	if valueType == "Vector3int16" then
		return { __type = "Vector3int16", x = value.X, y = value.Y, z = value.Z }
	end

	if valueType == "Color3" then
		return { __type = "Color3", r = value.R, g = value.G, b = value.B }
	end

	if valueType == "CFrame" then
		return { __type = "CFrame", components = { value:GetComponents() } }
	end

	if valueType == "UDim" then
		return { __type = "UDim", scale = value.Scale, offset = value.Offset }
	end

	if valueType == "UDim2" then
		return {
			__type = "UDim2",
			x = { scale = value.X.Scale, offset = value.X.Offset },
			y = { scale = value.Y.Scale, offset = value.Y.Offset },
		}
	end

	if valueType == "Ray" then
		return {
			__type = "Ray",
			origin = serialize(value.Origin, currentDepth + 1, visited),
			direction = serialize(value.Direction, currentDepth + 1, visited),
		}
	end

	if valueType == "Region3" then
		return {
			__type = "Region3",
			cframe = serialize(value.CFrame, currentDepth + 1, visited),
			size = serialize(value.Size, currentDepth + 1, visited),
		}
	end

	if valueType == "Region3int16" then
		return {
			__type = "Region3int16",
			min = serialize(value.Min, currentDepth + 1, visited),
			max = serialize(value.Max, currentDepth + 1, visited),
		}
	end

	if valueType == "BrickColor" then
		return {
			__type = "BrickColor",
			number = value.Number,
			name = value.Name,
			color = serialize(value.Color, currentDepth + 1, visited),
		}
	end

	if valueType == "EnumItem" then
		return { __type = "EnumItem", value = tostring(value) }
	end

	if valueType == "table" then
		if visited[value] then
			return "<cycle>"
		end

		visited[value] = true
		local output: {[string]: any} = {}
		local itemCount = 0

		for key, item in value do
			itemCount += 1

			if itemCount > MAX_TABLE_ITEMS then
				output["<truncated>"] = true
				break
			end

			output[tostring(key)] = serialize(item, currentDepth + 1, visited)
		end

		visited[value] = nil
		return output
	end

	return { __type = valueType, value = tostring(value) }
end

local function postEncoded(path: string, kind: string, payload: any): (boolean, any)
	local body = Encoder.encode({
		kind = kind,
		sentAt = DateTime.now().UnixTimestampMillis,
		payload = serialize(payload),
	}, runtimeProfile.encoder_rounds)

	return httpRequest(path, "POST", body)
end

local queue: {any} = {}
local queueHead = 1
local queueTail = 0
local flushing = false

local function queueSize(): number
	if queueTail < queueHead then
		return 0
	end

	return queueTail - queueHead + 1
end

local function enqueue(item: any)
	queueTail += 1
	queue[queueTail] = item
end

local function dequeueBatch(maxItems: number): {any}
	local batch = table.create(maxItems)
	local count = 0

	while queueHead <= queueTail and count < maxItems do
		count += 1
		batch[count] = queue[queueHead]
		queue[queueHead] = nil
		queueHead += 1
	end

	if queueHead > queueTail then
		queueHead = 1
		queueTail = 0
	end

	return batch
end

local trackedConnections: {[RBXScriptConnection]: boolean} = {}
local trackedConnectionCount = 0

local function trackConnection(connection: RBXScriptConnection): RBXScriptConnection
	if trackedConnections[connection] ~= true then
		trackedConnections[connection] = true
		trackedConnectionCount += 1
	end

	return connection
end

local recentCallsBySource: {[string]: {any}} = {}

local function rememberCall(record: any)
	if typeof(record) ~= "table" then
		return
	end

	local callsite = record.callsite
	if typeof(callsite) ~= "table" or typeof(callsite.source) ~= "string" then
		return
	end

	local source = callsite.source
	local entries = recentCallsBySource[source]

	if entries == nil then
		entries = {}
		recentCallsBySource[source] = entries
	end

	table.insert(entries, serialize(record))

	while #entries > MAX_RECENT_CALLS_PER_SOURCE do
		table.remove(entries, 1)
	end
end

type LatencySample = {
	at: number,
	durationMs: number,
}

local latencySamplesByRemote: {[string]: {LatencySample}} = {}

local function recordSuncLatency(message: any)
	if profilingConfig.enabled ~= true or typeof(message) ~= "table" then
		return
	end

	if message.channel ~= "SUNC" or typeof(message.durationMs) ~= "number" then
		return
	end

	local remote = message.remote
	if typeof(remote) ~= "table" or typeof(remote.path) ~= "string" then
		return
	end

	local path = remote.path
	local samples = latencySamplesByRemote[path]

	if samples == nil then
		samples = {}
		latencySamplesByRemote[path] = samples
	end

	table.insert(samples, {
		at = DateTime.now().UnixTimestampMillis,
		durationMs = math.max(0, message.durationMs),
	})
end

local function pruneLatencySamples(samples: {LatencySample}, nowMs: number)
	local windowMs = math.max(
		tonumber(profilingConfig.window_seconds) or 60,
		1
	) * 1000
	local cutoff = nowMs - windowMs
	local removeCount = 0

	for _, sample in samples do
		if sample.at < cutoff then
			removeCount += 1
		else
			break
		end
	end

	for _ = 1, removeCount do
		table.remove(samples, 1)
	end
end

local function calculatePerformanceStats(): {[string]: any}
	local nowMs = DateTime.now().UnixTimestampMillis
	local remotes: {[string]: any} = {}

	for path, samples in latencySamplesByRemote do
		pruneLatencySamples(samples, nowMs)

		if #samples > 0 then
			local values = table.create(#samples)
			local total = 0
			local minimum = math.huge
			local maximum = -math.huge

			for index, sample in samples do
				local value = sample.durationMs
				values[index] = value
				total += value
				minimum = math.min(minimum, value)
				maximum = math.max(maximum, value)
			end

			table.sort(values)
			local p95Index = math.clamp(math.ceil(#values * 0.95), 1, #values)

			remotes[path] = {
				count = #values,
				averageMs = total / #values,
				minMs = minimum,
				maxMs = maximum,
				p95Ms = values[p95Index],
			}
		end
	end

	return {
		enabled = profilingConfig.enabled == true,
		windowSeconds = tonumber(profilingConfig.window_seconds) or 60,
		capturedAt = nowMs,
		remotes = remotes,
	}
end

local function collectInstanceCounts(): {[string]: any}
	local counts: {[string]: number} = {}
	local descendants = game:GetDescendants()

	for _, instance in descendants do
		counts[instance.ClassName] = (counts[instance.ClassName] or 0) + 1
	end

	return {
		totalDescendants = #descendants,
		perClass = counts,
		capturedAt = DateTime.now().UnixTimestampMillis,
	}
end

local function collectGcStats(): {[string]: any}
	local heapKb = collectgarbage("count")

	return {
		luaHeapKb = heapKb,
		luaHeapBytesApprox = math.floor(heapKb * 1024),
		stepSupported = false,
		stepResult = nil,
		capturedAt = DateTime.now().UnixTimestampMillis,
	}
end

local function collectConnectionCounts(): {[string]: any}
	return {
		harnessTrackedConnections = trackedConnectionCount,
		globalEnumerationAvailable = false,
		scope = "harness_owned_only",
		capturedAt = DateTime.now().UnixTimestampMillis,
	}
end

local function targetIdentity(target: any): {[string]: any}
	if typeof(target) == "Instance" then
		local instance = target :: Instance

		return {
			kind = "Instance",
			name = instance.Name,
			path = instance:GetFullName(),
			ClassName = instance.ClassName,
		}
	end

	return {
		kind = typeof(target),
		name = tostring(target),
		path = tostring(target),
	}
end

local function sourceMatchesTarget(source: string, targetPath: string): boolean
	local lowerSource = string.lower(source)
	local lowerTarget = string.lower(targetPath)

	if string.find(lowerSource, lowerTarget, 1, true) ~= nil then
		return true
	end

	local targetName = string.match(targetPath, "([^%.]+)$")
	return targetName ~= nil
		and string.find(lowerSource, string.lower(targetName), 1, true) ~= nil
end

local function captureSupportedStack(target: any): {[string]: any}
	local frames = {}

	for level = 2, MAX_STACK_FRAMES + 1 do
		local source, line, functionName, argumentCount, variadic =
			debug.info(level, "slna")

		if source == nil then
			break
		end

		table.insert(frames, {
			level = level - 1,
			source = source,
			line = line,
			functionName = if functionName ~= "" then functionName else "<anonymous>",
			argumentCount = argumentCount,
			variadic = variadic,
		})
	end

	local identity = targetIdentity(target)
	local recentCalls = {}

	for source, records in recentCallsBySource do
		if sourceMatchesTarget(source, identity.path) then
			for _, record in records do
				table.insert(recentCalls, record)
			end
		end
	end

	while #recentCalls > MAX_RECENT_CALLS_PER_SOURCE do
		table.remove(recentCalls, 1)
	end

	return {
		target = identity,
		capturedAt = DateTime.now().UnixTimestampMillis,
		stack = frames,
		traceback = debug.traceback("HarnessX cooperative stack snapshot", 2),
		recentCalls = recentCalls,
		localsAvailable = false,
		upvaluesAvailable = false,
		limitations = {
			"Roblox Luau exposes debug.info and debug.traceback.",
			"debug.getlocal and debug.getupvalue are not available in the sandbox.",
			"The stack belongs to the cooperative GetScriptStack invocation.",
		},
	}
end

local function pushDiagnostics()
	local snapshots = {
		{
			path = "/v1/instance_counts",
			kind = "instance_counts",
			payload = collectInstanceCounts(),
		},
		{
			path = "/v1/gc_stats",
			kind = "gc_stats",
			payload = collectGcStats(),
		},
		{
			path = "/v1/connection_counts",
			kind = "connection_counts",
			payload = collectConnectionCounts(),
		},
		{
			path = "/v1/profiling/sunc",
			kind = "profiling_sunc",
			payload = calculatePerformanceStats(),
		},
	}

	for _, snapshot in snapshots do
		task.spawn(function()
			local ok, result = postEncoded(
				snapshot.path,
				snapshot.kind,
				snapshot.payload
			)

			if not ok then
				warn(
					`HarnessX diagnostic post failed for {snapshot.path}: `
						.. tostring(result)
				)
			end
		end)
	end
end

local function pushStackDump(target: any): {[string]: any}
	local dump = captureSupportedStack(target)

	task.spawn(function()
		local ok, result = postEncoded("/v1/stackdump", "stackdump", dump)

		if not ok then
			warn("HarnessX stack dump post failed: " .. tostring(result))
		end
	end)

	return dump
end

getInstanceCounts.OnInvoke = collectInstanceCounts
getGcStats.OnInvoke = collectGcStats
getConnectionCounts.OnInvoke = collectConnectionCounts
getScriptStack.OnInvoke = pushStackDump
getPerformanceStats.OnInvoke = calculatePerformanceStats

trackConnection(debugEvent.OnServerEvent:Connect(function(player: Player, message: any)
	rememberCall(message)
	recordSuncLatency(message)

	enqueue({
		player = {
			userId = player.UserId,
			name = player.Name,
		},
		message = message,
		serverReceivedAt = DateTime.now().UnixTimestampMillis,
	})
end))

debugFunction.OnServerInvoke = function(player: Player, message: any)
	rememberCall(message)

	local ok, response = postEncoded("/v1/invoke", "sunc_preflight", {
		player = {
			userId = player.UserId,
			name = player.Name,
		},
		message = message,
		serverReceivedAt = DateTime.now().UnixTimestampMillis,
	})

	if not ok then
		return {
			ok = false,
			mode = "observe",
			mockReturns = {},
			error = tostring(response),
		}
	end

	return response
end

fuzzControl.OnServerInvoke = function(player: Player, action: any, sessionId: any)
	local actionName = tostring(action)

	if actionName == "claim" then
		local ok, response = requestJson("/v1/fuzz/claim", "POST", {
			client = {
				userId = player.UserId,
				name = player.Name,
			},
		})

		if not ok then
			return {
				ok = false,
				error = tostring(response),
			}
		end

		return response
	elseif actionName == "status" then
		local safeId = HttpService:UrlEncode(tostring(sessionId or ""))
		local ok, response = httpRequest(
			"/v1/fuzz/status/" .. safeId,
			"GET",
			nil
		)

		if not ok then
			return {
				ok = false,
				error = tostring(response),
			}
		end

		return response
	end

	return {
		ok = false,
		error = "Unknown fuzz control action",
	}
end

trackConnection(fuzzReport.OnServerEvent:Connect(function(player: Player, message: any)
	if typeof(message) ~= "table" or typeof(message.sessionId) ~= "string" then
		return
	end

	local trace = {
		prefix = "[FUZZ]",
		channel = "FUZZ",
		phase = tostring(message.phase or "attempt"),
		sessionId = message.sessionId,
		target = message.target,
		targetClass = message.targetClass,
		attempt = message.attempt,
		latencyMs = message.latencyMs,
		error = message.error,
		player = {
			userId = player.UserId,
			name = player.Name,
		},
		serverReceivedAt = DateTime.now().UnixTimestampMillis,
	}

	task.spawn(function()
		local safeId = HttpService:UrlEncode(message.sessionId)
		local ok, result = postEncoded(
			"/v1/fuzz/report/" .. safeId,
			"fuzz_report",
			{
				player = trace.player,
				message = message,
			}
		)

		if not ok then
			warn("HarnessX fuzz report post failed: " .. tostring(result))
		end
	end)
end))

task.spawn(function()
	while true do
		local intervalSeconds = math.max(
			runtimeProfile.scan_interval_ms / 1000,
			0.05
		)

		task.wait(intervalSeconds)

		if not flushing and queueSize() > 0 then
			flushing = true
			local batchSize = math.max(1, math.floor(runtimeProfile.batch_size))
			local batch = dequeueBatch(batchSize)

			task.spawn(function()
				local ok, result = postEncoded("/v1/ingest", "remote_batch", {
					profile = runtimeProfileName,
					records = batch,
				})

				if not ok then
					warn("HarnessX batch post failed: " .. tostring(result))
				end

				flushing = false
			end)
		end
	end
end)

local lastDiagnosticTriggerId = 0
local lastStackRequestId = 0
local lastPeriodicDiagnosticAt = 0

task.spawn(function()
	while task.wait(1) do
		local statusOk, status = httpRequest("/v1/status", "GET", nil)

		if statusOk and typeof(status) == "table" then
			if typeof(status.profile) == "table" then
				runtimeProfile = status.profile
				runtimeProfileName = tostring(status.activeProfile)
			end

			if typeof(status.profiling) == "table" then
				profilingConfig = status.profiling
			end

			local diagnosticTriggerId = tonumber(status.diagnosticTriggerId) or 0
			if diagnosticTriggerId > lastDiagnosticTriggerId then
				lastDiagnosticTriggerId = diagnosticTriggerId
				pushDiagnostics()
			end

			local stackRequest = status.stackRequest
			if typeof(stackRequest) == "table" then
				local requestId = tonumber(stackRequest.id) or 0

				if requestId > lastStackRequestId then
					lastStackRequestId = requestId
					pushStackDump(stackRequest.target or "<unspecified>")
				end
			end
		end

		local now = os.clock()
		local periodicInterval = math.max(
			runtimeProfile.scan_interval_ms / 1000,
			5
		)

		if now - lastPeriodicDiagnosticAt >= periodicInterval then
			lastPeriodicDiagnosticAt = now
			pushDiagnostics()
		end

		task.spawn(function()
			postEncoded("/v1/runtime/status", "runtime_status", {
				pendingQueueSize = queueSize(),
				profile = runtimeProfileName,
				capturedAt = DateTime.now().UnixTimestampMillis,
			})
		end)
	end
end)

print(string.format(
	"HarnessX runtime ready: profile=%s interval=%sms batch=%s rounds=%s",
	runtimeProfileName,
	tostring(runtimeProfile.scan_interval_ms),
	tostring(runtimeProfile.batch_size),
	tostring(runtimeProfile.encoder_rounds)
))

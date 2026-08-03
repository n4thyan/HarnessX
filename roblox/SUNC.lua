if not game:GetService("RunService"):IsStudio() then return nil end

--[[
	Studio-only RemoteFunction source wrapper.

	No engine methods are overridden. The source-instrumentation plugin routes
	InvokeServer calls through this module. Observe, mock, and fuzz preflight
	modes are controlled by the authenticated loopback bridge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local packageFolder = ReplicatedStorage:WaitForChild("HarnessX")
local transportFolder = packageFolder:WaitForChild("Transport")
local debugEvent = transportFolder:WaitForChild("DebugEvent") :: RemoteEvent
local debugFunction = transportFolder:WaitForChild("DebugFunction") :: RemoteFunction
local UNC = require(packageFolder:WaitForChild("UNC"))

local SUNC = {}

SUNC.Materialize = UNC.Materialize
SUNC.BuildArguments = UNC.BuildArguments

local MAX_DEPTH = 6
local MAX_TABLE_ITEMS = 128
local MAX_INSTANCE_PROPERTIES = 5

local function vector3(value: Vector3): {[string]: any}
	return { __type = "Vector3", x = value.X, y = value.Y, z = value.Z }
end

local function color3(value: Color3): {[string]: any}
	return { __type = "Color3", r = value.R, g = value.G, b = value.B }
end

local serialize: (value: any, depth: number?, seen: {[any]: boolean}?) -> any

local function safeInstanceProperties(
	instance: Instance,
	depth: number,
	seen: {[any]: boolean}
): {[string]: any}
	local output: {[string]: any} = {}
	local count = 0

	for _, propertyName in {
		"Value",
		"Text",
		"Color",
		"BackgroundColor3",
		"Position",
	} do
		if count >= MAX_INSTANCE_PROPERTIES then
			break
		end

		local ok, propertyValue = pcall(function()
			return (instance :: any)[propertyName]
		end)

		if ok and propertyValue ~= nil then
			count += 1
			output[propertyName] = serialize(propertyValue, depth + 1, seen)
		end
	end

	return output
end

serialize = function(value: any, depth: number?, seen: {[any]: boolean}?): any
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
			properties = safeInstanceProperties(instance, currentDepth, visited),
		}
	end

	if valueType == "Vector2" then
		return { __type = "Vector2", x = value.X, y = value.Y }
	end

	if valueType == "Vector3" then
		return vector3(value)
	end

	if valueType == "Vector3int16" then
		return { __type = "Vector3int16", x = value.X, y = value.Y, z = value.Z }
	end

	if valueType == "Color3" then
		return color3(value)
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
			origin = vector3(value.Origin),
			direction = vector3(value.Direction),
		}
	end

	if valueType == "Region3" then
		return {
			__type = "Region3",
			cframe = serialize(value.CFrame, currentDepth + 1, visited),
			size = vector3(value.Size),
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
			color = color3(value.Color),
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

local function callsite(): {[string]: any}
	local source, line, functionName = debug.info(2, "sln")

	return {
		source = source or "<unknown>",
		line = line or -1,
		functionName = if functionName ~= "" then functionName else "<anonymous>",
	}
end

local function remoteIdentity(remote: RemoteFunction): {[string]: any}
	return {
		name = remote.Name,
		ClassName = remote.ClassName,
		path = remote:GetFullName(),
	}
end

local function submitTrace(record: any)
	task.defer(function()
		local ok, sendError = pcall(function()
			debugEvent:FireServer(record)
		end)

		if not ok then
			warn("HarnessX SUNC trace failed: " .. tostring(sendError))
		end
	end)
end

function SUNC.InvokeServer(remote: RemoteFunction, ...: any): ...any
	assert(
		typeof(remote) == "Instance" and remote:IsA("RemoteFunction"),
		"SUNC.InvokeServer expected a RemoteFunction"
	)

	local arguments = table.pack(...)
	local identity = remoteIdentity(remote)
	local sourceLocation = callsite()
	local startedAt = os.clock()

	local preflightRecord = {
		channel = "SUNC",
		direction = "client_to_server",
		phase = "preflight",
		remote = identity,
		callsite = sourceLocation,
		argumentCount = arguments.n,
		arguments = serialize(arguments),
		clientTime = DateTime.now().UnixTimestampMillis,
	}

	local preflightOk, preflightResponse = pcall(function()
		return debugFunction:InvokeServer(preflightRecord)
	end)

	if preflightOk and typeof(preflightResponse) == "table" then
		local mode = string.lower(tostring(preflightResponse.mode or "observe"))

		if mode == "mock" then
			local mockReturns = preflightResponse.mockReturns

			if typeof(mockReturns) ~= "table" then
				mockReturns = {}
			end

			submitTrace({
				channel = "SUNC",
				direction = "server_to_client",
				phase = "mocked",
				remote = identity,
				callsite = sourceLocation,
				durationMs = math.floor((os.clock() - startedAt) * 1000),
				returnCount = #mockReturns,
				returns = serialize(mockReturns),
				clientTime = DateTime.now().UnixTimestampMillis,
			})

			return table.unpack(mockReturns, 1, #mockReturns)
		elseif mode == "fuzz" then
			-- A fuzz preflight may provide a replacement argument template.
			-- If none is supplied, the current arguments are treated as the
			-- template. Complex descriptors are materialized through UNC.
			local template = preflightResponse.arguments or arguments
			arguments = SUNC.BuildArguments(template)

			submitTrace({
				channel = "SUNC",
				direction = "client_to_server",
				phase = "fuzz_materialized",
				remote = identity,
				callsite = sourceLocation,
				argumentCount = arguments.n,
				arguments = serialize(arguments),
				clientTime = DateTime.now().UnixTimestampMillis,
			})
		end
	elseif not preflightOk then
		submitTrace({
			channel = "SUNC",
			direction = "local_bridge",
			phase = "preflight_failed",
			remote = identity,
			callsite = sourceLocation,
			error = tostring(preflightResponse),
			clientTime = DateTime.now().UnixTimestampMillis,
		})
	end

	local packedCall = table.pack(pcall(function()
		return remote:InvokeServer(table.unpack(arguments, 1, arguments.n))
	end))

	if packedCall[1] ~= true then
		local invokeError = tostring(packedCall[2])

		submitTrace({
			channel = "SUNC",
			direction = "server_to_client",
			phase = "invoke_error",
			remote = identity,
			callsite = sourceLocation,
			durationMs = math.floor((os.clock() - startedAt) * 1000),
			error = invokeError,
			clientTime = DateTime.now().UnixTimestampMillis,
		})

		error(invokeError, 0)
	end

	local returnCount = packedCall.n - 1
	local returnValues = table.create(returnCount)

	for index = 1, returnCount do
		returnValues[index] = packedCall[index + 1]
	end

	returnValues.n = returnCount

	submitTrace({
		channel = "SUNC",
		direction = "server_to_client",
		phase = "returned",
		remote = identity,
		callsite = sourceLocation,
		durationMs = math.floor((os.clock() - startedAt) * 1000),
		returnCount = returnCount,
		returns = serialize(returnValues),
		clientTime = DateTime.now().UnixTimestampMillis,
	})

	return table.unpack(returnValues, 1, returnCount)
end

return table.freeze(SUNC)

if not game:GetService("RunService"):IsStudio() then return nil end

--[[
	Studio-only RemoteEvent source wrapper and fuzz-value materializer.

	No Roblox engine methods are replaced. Calls are routed here by the
	source-instrumentation plugin, logged through DebugEvent, and then forwarded
	to the original RemoteEvent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local packageFolder = ReplicatedStorage:WaitForChild("HarnessX")
local transportFolder = packageFolder:WaitForChild("Transport")
local debugEvent = transportFolder:WaitForChild("DebugEvent") :: RemoteEvent

local UNC = {}

local MAX_DEPTH = 6
local MAX_TABLE_ITEMS = 128
local MAX_INSTANCE_PROPERTIES = 5
local DEFAULT_RANDOM_MIN = -100
local DEFAULT_RANDOM_MAX = 100
local DEFAULT_STRING_LENGTH = 12
local RANDOM_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function resolveInstancePath(path: string): Instance?
	local segments = string.split(path, ".")
	local current: Instance = game
	local startIndex = 1

	if segments[1] == "game" then
		startIndex = 2
	end

	for index = startIndex, #segments do
		local segment = segments[index]

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

local function resolveEnumItem(path: string): EnumItem?
	local segments = string.split(path, ".")

	if #segments < 3 or segments[1] ~= "Enum" then
		return nil
	end

	local enumType = (Enum :: any)[segments[2]]
	if enumType == nil then
		return nil
	end

	return enumType[segments[3]]
end

local function randomNumber(minimum: any, maximum: any): number
	local minValue = tonumber(minimum) or DEFAULT_RANDOM_MIN
	local maxValue = tonumber(maximum) or DEFAULT_RANDOM_MAX

	if maxValue < minValue then
		minValue, maxValue = maxValue, minValue
	end

	return minValue + math.random() * (maxValue - minValue)
end

local function randomString(lengthValue: any): string
	local length = math.clamp(
		math.floor(tonumber(lengthValue) or DEFAULT_STRING_LENGTH),
		0,
		256
	)
	local output = table.create(length)

	for index = 1, length do
		local alphabetIndex = math.random(1, #RANDOM_ALPHABET)
		output[index] = string.sub(
			RANDOM_ALPHABET,
			alphabetIndex,
			alphabetIndex
		)
	end

	return table.concat(output)
end

local function vector3FromDescriptor(descriptor: {[any]: any}): Vector3
	if descriptor.random == true or descriptor.__type == "RandomVector3" then
		local minimum = descriptor.min or DEFAULT_RANDOM_MIN
		local maximum = descriptor.max or DEFAULT_RANDOM_MAX

		return Vector3.new(
			randomNumber(descriptor.minX or minimum, descriptor.maxX or maximum),
			randomNumber(descriptor.minY or minimum, descriptor.maxY or maximum),
			randomNumber(descriptor.minZ or minimum, descriptor.maxZ or maximum)
		)
	end

	return Vector3.new(
		tonumber(descriptor.x) or 0,
		tonumber(descriptor.y) or 0,
		tonumber(descriptor.z) or 0
	)
end

local function cframeFromDescriptor(descriptor: {[any]: any}): CFrame
	local components = descriptor.components

	if typeof(components) == "table" and #components == 12 then
		return CFrame.new(table.unpack(components, 1, 12))
	end

	if descriptor.random == true or descriptor.__type == "RandomCFrame" then
		local minimum = descriptor.min or DEFAULT_RANDOM_MIN
		local maximum = descriptor.max or DEFAULT_RANDOM_MAX
		local position = Vector3.new(
			randomNumber(descriptor.minX or minimum, descriptor.maxX or maximum),
			randomNumber(descriptor.minY or minimum, descriptor.maxY or maximum),
			randomNumber(descriptor.minZ or minimum, descriptor.maxZ or maximum)
		)

		local maxRotation = tonumber(descriptor.maxRotationDegrees) or 180
		local rx = math.rad(randomNumber(-maxRotation, maxRotation))
		local ry = math.rad(randomNumber(-maxRotation, maxRotation))
		local rz = math.rad(randomNumber(-maxRotation, maxRotation))

		return CFrame.new(position) * CFrame.Angles(rx, ry, rz)
	end

	local positionDescriptor = descriptor.position
	local position = if typeof(positionDescriptor) == "table"
		then vector3FromDescriptor(positionDescriptor)
		else Vector3.new(
			tonumber(descriptor.x) or 0,
			tonumber(descriptor.y) or 0,
			tonumber(descriptor.z) or 0
		)

	return CFrame.new(position)
end

function UNC.Materialize(value: any): any
	if value == "random" then
		return math.random()
	end

	if typeof(value) ~= "table" then
		return value
	end

	local descriptor = value :: {[any]: any}
	local descriptorType = tostring(descriptor.__type or "")

	if descriptorType == "number" or descriptorType == "RandomNumber" then
		if descriptor.random == true or descriptorType == "RandomNumber" then
			return randomNumber(descriptor.min, descriptor.max)
		end
		return tonumber(descriptor.value) or 0
	end

	if descriptorType == "string" or descriptorType == "RandomString" then
		if descriptor.random == true or descriptorType == "RandomString" then
			return randomString(descriptor.length)
		end
		return tostring(descriptor.value or "")
	end

	if descriptorType == "boolean" or descriptorType == "RandomBoolean" then
		if descriptor.random == true or descriptorType == "RandomBoolean" then
			return math.random(0, 1) == 1
		end
		return descriptor.value == true
	end

	if descriptorType == "Vector3" or descriptorType == "RandomVector3" then
		return vector3FromDescriptor(descriptor)
	end

	if descriptorType == "CFrame" or descriptorType == "RandomCFrame" then
		return cframeFromDescriptor(descriptor)
	end

	if descriptorType == "InstancePath" or descriptorType == "Instance" then
		return resolveInstancePath(tostring(descriptor.path or descriptor.value or ""))
	end

	if descriptorType == "EnumItem" then
		return resolveEnumItem(tostring(descriptor.value or descriptor.path or ""))
	end

	if descriptorType == "Random" then
		local expectedType = string.lower(
			tostring(descriptor.expectedType or "number")
		)
		local mappedTypes = {
			number = "RandomNumber",
			string = "RandomString",
			boolean = "RandomBoolean",
			vector3 = "RandomVector3",
			cframe = "RandomCFrame",
		}
		local nested = table.clone(descriptor)
		nested.__type = mappedTypes[expectedType] or "RandomNumber"
		return UNC.Materialize(nested)
	end

	local output: {[any]: any} = {}

	for key, item in descriptor do
		output[key] = UNC.Materialize(item)
	end

	return output
end

function UNC.BuildArguments(template: any): {any}
	if typeof(template) ~= "table" then
		return { UNC.Materialize(template) }
	end

	local output = {}
	local count = tonumber(template.n) or #template

	for index = 1, count do
		output[index] = UNC.Materialize(template[index])
	end

	output.n = count
	return output
end

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

function UNC.FireServer(remote: RemoteEvent, ...: any)
	assert(
		typeof(remote) == "Instance" and remote:IsA("RemoteEvent"),
		"UNC.FireServer expected a RemoteEvent"
	)

	local arguments = table.pack(...)

	local record = {
		channel = "UNC",
		direction = "client_to_server",
		phase = "before_send",
		remote = {
			name = remote.Name,
			ClassName = remote.ClassName,
			path = remote:GetFullName(),
		},
		callsite = callsite(),
		argumentCount = arguments.n,
		arguments = serialize(arguments),
		clientTime = DateTime.now().UnixTimestampMillis,
	}

	task.defer(function()
		local ok, sendError = pcall(function()
			debugEvent:FireServer(record)
		end)

		if not ok then
			warn("HarnessX UNC trace failed: " .. tostring(sendError))
		end
	end)

	remote:FireServer(table.unpack(arguments, 1, arguments.n))
end

return table.freeze(UNC)

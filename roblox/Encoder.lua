if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

-- Studio-only transport encoder.
--
-- This is reversible transport obfuscation, not encryption. It applies a
-- rolling XOR using a timestamp-derived nonce, then writes the transformed
-- bytes as hexadecimal. server/encoder.py implements the matching decoder.

local HttpService = game:GetService("HttpService")

local Encoder = {}
local UINT32 = 4294967296

local function keyByte(nonceByte: number, roundIndex: number, byteIndex: number): number
	return (nonceByte + roundIndex * 31 + byteIndex * 17) % 256
end

local function transform(input: string, nonceByte: number, rounds: number): string
	local output = input

	for roundIndex = 1, rounds do
		local transformed = table.create(#output)

		for byteIndex = 1, #output do
			local sourceByte = string.byte(output, byteIndex)
			local key = keyByte(nonceByte, roundIndex, byteIndex)
			transformed[byteIndex] = string.char(bit32.bxor(sourceByte, key))
		end

		output = table.concat(transformed)
	end

	return output
end

local function toHex(input: string): string
	local output = table.create(#input)

	for index = 1, #input do
		output[index] = string.format("%02x", string.byte(input, index))
	end

	return table.concat(output)
end

local function fromHex(input: string): (string?, string?)
	if #input % 2 ~= 0 or string.match(input, "^[0-9a-fA-F]*$") == nil then
		return nil, "Invalid hexadecimal payload"
	end

	local output = table.create(#input / 2)
	local outputIndex = 0

	for index = 1, #input, 2 do
		outputIndex += 1
		local byteValue = tonumber(string.sub(input, index, index + 1), 16)
		if byteValue == nil then
			return nil, "Invalid hexadecimal byte"
		end
		output[outputIndex] = string.char(byteValue)
	end

	return table.concat(output), nil
end

function Encoder.encode(value: any, rounds: number): string
	assert(typeof(rounds) == "number", "rounds must be a number")
	rounds = math.floor(rounds)
	assert(rounds >= 1 and rounds <= 16, "rounds must be between 1 and 16")

	local nonce = DateTime.now().UnixTimestampMillis
	local nonceByte = nonce % 256
	local jsonPayload = HttpService:JSONEncode(value)
	local transformed = transform(jsonPayload, nonceByte, rounds)

	return HttpService:JSONEncode({
		version = 1,
		algorithm = "rolling-xor-hex",
		nonce = nonce,
		rounds = rounds,
		data = toHex(transformed),
	})
end

function Encoder.decode(envelopeJson: string): (any?, string?)
	local envelopeOk, envelope = pcall(function()
		return HttpService:JSONDecode(envelopeJson)
	end)

	if not envelopeOk or typeof(envelope) ~= "table" then
		return nil, "Envelope is not valid JSON"
	end

	if envelope.version ~= 1 or envelope.algorithm ~= "rolling-xor-hex" then
		return nil, "Unsupported encoder envelope"
	end

	if typeof(envelope.nonce) ~= "number"
		or typeof(envelope.rounds) ~= "number"
		or typeof(envelope.data) ~= "string"
	then
		return nil, "Envelope fields are invalid"
	end

	local transformed, hexError = fromHex(envelope.data)
	if transformed == nil then
		return nil, hexError
	end

	-- XOR is self-inverse, but multi-round decoding must reverse round order.
	local output = transformed
	local nonceByte = envelope.nonce % 256

	for roundIndex = math.floor(envelope.rounds), 1, -1 do
		local decoded = table.create(#output)

		for byteIndex = 1, #output do
			local sourceByte = string.byte(output, byteIndex)
			local key = keyByte(nonceByte, roundIndex, byteIndex)
			decoded[byteIndex] = string.char(bit32.bxor(sourceByte, key))
		end

		output = table.concat(decoded)
	end

	local payloadOk, payload = pcall(function()
		return HttpService:JSONDecode(output)
	end)

	if not payloadOk then
		return nil, "Decoded payload is not valid JSON"
	end

	return payload, nil
end

return table.freeze(Encoder)

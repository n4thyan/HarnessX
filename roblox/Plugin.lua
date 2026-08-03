if not game:GetService("RunService"):IsStudio() then return nil end
if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

assert(plugin, "Plugin.lua must run as a Roblox Studio plugin")

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptEditorService = game:GetService("ScriptEditorService")

local URL = "http://127.0.0.1:8765"
local tokenAttribute = game:GetAttribute("HarnessXBridgeToken")

if typeof(tokenAttribute) ~= "string" or #tokenAttribute < 16 then
	warn(
		"HarnessX plugin stopped: set the HarnessXBridgeToken game attribute "
			.. "to the same value as config.json bridge.token."
	)
	return nil
end

local TOKEN = tokenAttribute :: string
local HEADER = "-- <HarnessX:instrumented>"
local IGNORE_ATTRIBUTE = "HarnessXIgnore"
local enabled = plugin:GetSetting("HarnessXEnabled") ~= false

local function request(path: string, method: string, body: any?): (boolean, any)
	local options: {[string]: any} = {
		Url = URL .. path,
		Method = method,
		Headers = {
			["Accept"] = "application/json",
			["Content-Type"] = "application/json",
			["X-Debug-Token"] = TOKEN,
		},
	}
	if body ~= nil then options.Body = HttpService:JSONEncode(body) end
	local ok, response = pcall(function() return HttpService:RequestAsync(options) end)
	if not ok then return false, tostring(response) end
	if not response.Success then
		return false, string.format("HTTP %s: %s", response.StatusCode, response.Body)
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodedOk then return false, "Invalid JSON response" end
	return true, decoded
end

local configOk, bridgeConfig = request("/v1/config", "GET", nil)
if not configOk or typeof(bridgeConfig) ~= "table" then bridgeConfig = {} end
local pluginConfig = if typeof(bridgeConfig.plugin) == "table" then bridgeConfig.plugin else {}
if pluginConfig.enabled == false then
	warn("HarnessX plugin is disabled by config.json")
	return nil
end
local fuzzerConfig = if typeof(bridgeConfig.fuzzer) == "table" then bridgeConfig.fuzzer else {}
local excludeAttribute = tostring(pluginConfig.exclude_scripts_with_attribute or IGNORE_ATTRIBUTE)
local wrapperStyle = if string.lower(tostring(pluginConfig.wrapper_style or "UNC")) == "remoteproxy"
	then "RemoteProxy"
	else "UNC"

local function isScript(instance: Instance): boolean
	return instance:IsA("Script") or instance:IsA("LocalScript") or instance:IsA("ModuleScript")
end

local function excluded(instance: Instance): boolean
	local current: Instance? = instance
	while current do
		if current:GetAttribute(excludeAttribute) == true then return true end
		current = current.Parent
	end
	local folder = ReplicatedStorage:FindFirstChild("HarnessX")
	return folder ~= nil and instance:IsDescendantOf(folder)
end

local function scripts(): {Instance}
	local result = {}
	for _, instance in game:GetDescendants() do
		if isScript(instance) and not excluded(instance) then table.insert(result, instance) end
	end
	table.sort(result, function(a, b) return a:GetFullName() < b:GetFullName() end)
	return result
end

local function skipQuotedString(source: string, index: number): number
	local quote = source:sub(index, index)
	local cursor = index + 1
	while cursor <= #source do
		local character = source:sub(cursor, cursor)
		if character == "\\" then cursor += 2
		elseif character == quote then return cursor + 1
		else cursor += 1 end
	end
	return #source + 1
end

local function longBracketEnd(source: string, index: number): number?
	local equals = source:sub(index):match("^%[(=*)%[")
	if equals == nil then return nil end
	local closeToken = "]" .. equals .. "]"
	local contentStart = index + #equals + 2
	local closeStart = source:find(closeToken, contentStart, true)
	return if closeStart ~= nil then closeStart + #closeToken else #source + 1
end

local function maskRange(output: {string}, source: string, first: number, finish: number)
	for position = first, finish - 1 do
		output[position] = if source:sub(position, position) == "\n" then "\n" else " "
	end
end

local function codeMask(source: string): string
	local output = table.create(#source)
	local index = 1
	while index <= #source do
		local one = source:sub(index, index)
		local two = source:sub(index, index + 1)
		if two == "--" then
			local blockFinish = longBracketEnd(source, index + 2)
			local finish = blockFinish or (source:find("\n", index + 2, true) or (#source + 1))
			maskRange(output, source, index, finish)
			index = finish
		elseif one == "'" or one == '"' or one == "`" then
			local finish = skipQuotedString(source, index)
			maskRange(output, source, index, finish)
			index = finish
		elseif one == "[" then
			local finish = longBracketEnd(source, index)
			if finish ~= nil then
				maskRange(output, source, index, finish)
				index = finish
			else
				output[index] = one
				index += 1
			end
		else
			output[index] = one
			index += 1
		end
	end
	return table.concat(output)
end

local function receiverStart(mask: string, colon: number): number
	local paren, bracket, brace = 0, 0, 0
	local index = colon - 1
	while index > 0 do
		local character = mask:sub(index, index)
		if character == ")" then paren += 1
		elseif character == "]" then bracket += 1
		elseif character == "}" then brace += 1
		elseif character == "(" then
			if paren > 0 then paren -= 1 else break end
		elseif character == "[" then
			if bracket > 0 then bracket -= 1 else break end
		elseif character == "{" then
			if brace > 0 then brace -= 1 else break end
		elseif paren == 0 and bracket == 0 and brace == 0
			and character:match("[,;=+%-%*/%%%^<>\n]") then break end
		index -= 1
	end
	return index + 1
end

local function prependInstrumentationHeader(source: string, header: string): string
	local insertion = 1
	local cursor = 1
	while cursor <= #source do
		local newline = source:find("\n", cursor, true)
		local finish = newline or (#source + 1)
		local line = source:sub(cursor, finish - 1)
		if line:match("^%s*%-%-!") == nil then break end
		insertion = finish + (if newline ~= nil then 1 else 0)
		cursor = insertion
	end
	return source:sub(1, insertion - 1) .. header .. source:sub(insertion)
end

local function rewriteSource(source: string): (string, number)
	local rewritten = source
	local count = 0
	while count < 1000 do
		local mask = codeMask(rewritten)
		local bestColon, bestOpen, bestMethod, bestReceiverStart
		for _, method in { "FireServer", "InvokeServer" } do
			local cursor = 1
			while true do
				local colon, methodEnd = mask:find(":" .. method .. "%s*%(", cursor)
				if not colon then break end
				local open = mask:find("(", colon, true)
				local start = receiverStart(mask, colon)
				local receiverMask = mask:sub(start, colon - 1)
				local alreadyProxy = receiverMask:match("^%s*__rp%.wrap%s*%(") ~= nil
				if open and not alreadyProxy and (not bestColon or colon > bestColon) then
					bestColon, bestOpen, bestMethod, bestReceiverStart = colon, open, method, start
				end
				cursor = methodEnd + 1
			end
		end
		if not bestColon or not bestOpen or not bestMethod or not bestReceiverStart then break end
		local receiver = rewritten:sub(bestReceiverStart, bestColon - 1)
		local afterOpen = mask:match("^%s*%)", bestOpen + 1) ~= nil
		local replacement: string
		if wrapperStyle == "RemoteProxy" then
			replacement = "__rp.wrap(" .. receiver .. "):" .. bestMethod .. "("
		else
			local wrapper = if bestMethod == "FireServer" then "UNC.FireServer" else "SUNC.InvokeServer"
			replacement = wrapper .. "(" .. receiver .. (if afterOpen then "" else ", ")
		end
		rewritten = rewritten:sub(1, bestReceiverStart - 1) .. replacement .. rewritten:sub(bestOpen + 1)
		count += 1
	end
	if count > 0 then
		if wrapperStyle == "RemoteProxy" then
			local requireLine = 'local __rp = require(game.ReplicatedStorage.HarnessX.RemoteProxy)'
			if not rewritten:find(requireLine, 1, true) then
				if rewritten:find(HEADER, 1, true) then
					rewritten = rewritten:gsub(HEADER, HEADER .. "\n" .. requireLine, 1)
				else
					local header = table.concat({
						HEADER,
						requireLine,
						"-- </HarnessX:instrumented>",
						"",
					}, "\n")
					rewritten = prependInstrumentationHeader(rewritten, header)
				end
			end
		elseif not rewritten:find(HEADER, 1, true) then
			local header = table.concat({
				HEADER,
				'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
				'local __HarnessX = ReplicatedStorage:WaitForChild("HarnessX")',
				'local UNC = require(__HarnessX:WaitForChild("UNC"))',
				'local SUNC = require(__HarnessX:WaitForChild("SUNC"))',
				"-- </HarnessX:instrumented>",
				"",
			}, "\n")
			rewritten = prependInstrumentationHeader(rewritten, header)
		end
	end
	return rewritten, count
end

local function updateScript(target: Instance, transform: (string) -> string): (boolean, string?)
	local changed = false
	local ok, updateError = pcall(function()
		ScriptEditorService:UpdateSourceAsync(target :: any, function(oldSource)
			local newSource = transform(oldSource)
			changed = newSource ~= oldSource
			return newSource
		end)
	end)
	return changed, if ok then nil else tostring(updateError)
end

local toolbar = plugin:CreateToolbar("HarnessX")
local dashboardButton = toolbar:CreateButton("Dashboard", "Open HarnessX", "")
local rewriteButton = toolbar:CreateButton("Rewrite", "Instrument remote calls", "")
local backupButton = toolbar:CreateButton("Backup", "Back up eligible scripts", "")
local toggleButton = toolbar:CreateButton("Toggle", "Toggle auto instrumentation", "")
toggleButton:SetActive(enabled)

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"HarnessXDashboardV2",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 620, 720, 380, 320)
)
widget.Title = "HarnessX"

local COLORS = {
	bg = Color3.fromRGB(24, 26, 31), panel = Color3.fromRGB(34, 37, 44),
	button = Color3.fromRGB(49, 54, 64), text = Color3.fromRGB(235, 238, 245),
	muted = Color3.fromRGB(160, 168, 182), accent = Color3.fromRGB(88, 166, 255),
	good = Color3.fromRGB(80, 200, 120), bad = Color3.fromRGB(235, 90, 90),
}

local function make(className: string, properties: {[string]: any}, parent: Instance?): Instance
	local instance = Instance.new(className)
	for key, value in properties do (instance :: any)[key] = value end
	if parent then instance.Parent = parent end
	return instance
end

local root = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = COLORS.bg, BorderSizePixel = 0 }, widget) :: Frame
local status = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = COLORS.panel, BorderSizePixel = 0,
	Text = "HarnessX bridge: connecting", TextColor3 = COLORS.muted, Font = Enum.Font.Code,
	TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
}, root) :: TextLabel
local tabs = make("Frame", { Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = COLORS.panel, BorderSizePixel = 0 }, root) :: Frame
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, tabs)
local content = make("Frame", { Position = UDim2.new(0, 0, 0, 70), Size = UDim2.new(1, 0, 1, -70), BackgroundTransparency = 1 }, root) :: Frame
local pages: {[string]: Frame} = {}
local tabButtons: {[string]: TextButton} = {}

local function page(name: string): Frame
	local frame = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, content) :: Frame
	pages[name] = frame
	return frame
end

local function show(name: string)
	for key, frame in pages do frame.Visible = key == name end
	for key, button in tabButtons do button.BackgroundColor3 = if key == name then COLORS.accent else COLORS.button end
end

local function tab(name: string)
	local button = make("TextButton", {
		Size = UDim2.new(0, 90, 1, 0), BackgroundColor3 = COLORS.button, BorderSizePixel = 0,
		Text = name, TextColor3 = COLORS.text, Font = Enum.Font.SourceSansSemibold, TextSize = 14,
	}, tabs) :: TextButton
	tabButtons[name] = button
	button.Activated:Connect(function() show(name) end)
end

local trafficPage, scriptsPage, controlsPage, fuzzerPage = page("Traffic"), page("Scripts"), page("Controls"), page("Fuzzer")
tab("Traffic") tab("Scripts") tab("Controls") tab("Fuzzer")

local function scrolling(parent: Instance): ScrollingFrame
	local frame = make("ScrollingFrame", {
		Position = UDim2.new(0, 6, 0, 6), Size = UDim2.new(1, -12, 1, -12),
		BackgroundColor3 = COLORS.panel, BorderSizePixel = 0, AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(), ScrollBarThickness = 7,
	}, parent) :: ScrollingFrame
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
	return frame
end

local trafficList = scrolling(trafficPage)
local scriptsList = scrolling(scriptsPage)
local selectedScript: Instance? = nil
local selectedRemote: Instance? = nil
local activeSession: string? = nil
local sequence = 0

local function clearGui(parent: Instance)
	for _, child in parent:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
end

local function button(parent: Instance, text: string, callback: () -> ()): TextButton
	local result = make("TextButton", {
		Size = UDim2.new(1, -8, 0, 34), BackgroundColor3 = COLORS.button, BorderSizePixel = 0,
		Text = text, TextColor3 = COLORS.text, Font = Enum.Font.SourceSansSemibold, TextSize = 14,
	}, parent) :: TextButton
	result.Activated:Connect(callback)
	return result
end

local function instancePathSegments(instance: Instance): {string}
	local result = {}
	local current: Instance? = instance
	while current ~= nil and current ~= game do
		table.insert(result, 1, current.Name)
		current = current.Parent
	end
	return result
end

local function backupAll()
	local sourceEntries = {}
	for _, target in scripts() do
		local ok, source = pcall(function() return ScriptEditorService:GetEditorSource(target :: any) end)
		if ok then
			table.insert(sourceEntries, {
				path = target:GetFullName(),
				segments = instancePathSegments(target),
				className = target.ClassName,
				source = source,
			})
		end
	end
	local ok, response = request("/v1/backup/sources", "POST", { sources = sourceEntries })
	status.Text = if ok then "Backup: " .. tostring(response.folder) else "Backup failed: " .. tostring(response)
end

local function matchingParen(mask: string, open: number): number?
	local depth = 0
	for index = open, #mask do
		local character = mask:sub(index, index)
		if character == "(" then depth += 1
		elseif character == ")" then
			depth -= 1
			if depth == 0 then return index end
		end
	end
	return nil
end

local function traceInstrumentedCalls(source: string): string
	local mask = codeMask(source)
	local ranges = {}
	for _, definition in {
		{ pattern = "UNC%.FireServer%s*%(", kind = "UNC" },
		{ pattern = "SUNC%.InvokeServer%s*%(", kind = "SUNC" },
	} do
		local cursor = 1
		while true do
			local first = mask:find(definition.pattern, cursor)
			if first == nil then break end
			local open = mask:find("(", first, true)
			local finish = if open ~= nil then matchingParen(mask, open) else nil
			if finish == nil then break end
			table.insert(ranges, { first = first, finish = finish, kind = definition.kind })
			cursor = finish + 1
		end
	end

	local cursor = 1
	while true do
		local first = mask:find("__rp%.wrap%s*%(", cursor)
		if first == nil then break end
		local wrapOpen = mask:find("(", first, true)
		local wrapFinish = if wrapOpen ~= nil then matchingParen(mask, wrapOpen) else nil
		if wrapFinish == nil then break end
		local tail = mask:sub(wrapFinish + 1)
		local _, fireEnd = tail:find("^%s*:%s*FireServer%s*%(")
		local _, invokeEnd = tail:find("^%s*:%s*InvokeServer%s*%(")
		local tailEnd = fireEnd or invokeEnd
		if tailEnd ~= nil then
			local callOpen = mask:find("(", wrapFinish + 1, true)
			local callFinish = if callOpen ~= nil then matchingParen(mask, callOpen) else nil
			if callFinish ~= nil then
				table.insert(ranges, { first = first, finish = callFinish, kind = "RemoteProxy" })
				cursor = callFinish + 1
				continue
			end
		end
		cursor = wrapFinish + 1
	end

	table.sort(ranges, function(a, b) return a.first > b.first end)
	local rewritten = source
	for _, range in ranges do
		local call = rewritten:sub(range.first, range.finish)
		local replacement = '__HarnessTrace("' .. range.kind .. '", function() return ' .. call .. ' end)'
		rewritten = rewritten:sub(1, range.first - 1) .. replacement .. rewritten:sub(range.finish + 1)
	end
	return rewritten
end

local function injectTrace(target: Instance)
	local recording = ChangeHistoryService:TryBeginRecording("HarnessXTrace", "Inject HarnessX trace")
	if not recording then return end
	local changed, updateError = updateScript(target, function(source)
		if source:find("-- <HarnessX:trace-injected>", 1, true) then return source end
		local traced = traceInstrumentedCalls(source)
		if traced == source then return source end
		local helper = table.concat({
			"-- <HarnessX:trace-injected>",
			"local function __HarnessTrace(kind, callback)",
			"\tprint(\"[HarnessX] Calling\", kind)",
			"\tlocal result = table.pack(pcall(callback))",
			"\tprint(\"[HarnessX] Call finished\", kind)",
			"\tif not result[1] then error(result[2], 0) end",
			"\treturn table.unpack(result, 2, result.n)",
			"end",
			"-- </HarnessX:trace-injected>",
			"",
		}, "\n")
		return prependInstrumentationHeader(traced, helper)
	end)
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	status.Text = if updateError then updateError elseif changed then "Trace injected" else "No untraced wrapper calls found"
end

local function refreshScripts()
	clearGui(scriptsList)
	for _, target in scripts() do
		local ok, source = pcall(function() return ScriptEditorService:GetEditorSource(target :: any) end)
		local count = 0
		if ok then
			local _, unc = source:gsub("UNC%.FireServer%(", "")
			local _, sunc = source:gsub("SUNC%.InvokeServer%(", "")
			local _, remoteProxy = source:gsub("__rp%.wrap%(", "")
			count = unc + sunc + remoteProxy
		end
		button(scriptsList, string.format("%s  [%d]", target:GetFullName(), count), function()
			selectedScript = target
			status.Text = "Selected script: " .. target:GetFullName()
		end)
	end
	button(scriptsList, "Inject trace into selected", function()
		if selectedScript then injectTrace(selectedScript) end
	end)
	button(scriptsList, "Backup all", backupAll)
end

local function rewriteAll()
	local recording = ChangeHistoryService:TryBeginRecording("HarnessXRewrite", "Instrument remote calls")
	if not recording then return end
	local calls, failures = 0, 0
	for _, target in scripts() do
		local _, updateError = updateScript(target, function(source)
			local rewritten, count = rewriteSource(source)
			calls += count
			return rewritten
		end)
		if updateError then failures += 1 end
	end
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	status.Text = string.format("Rewrote %d calls; %d failures", calls, failures)
	refreshScripts()
end

local controls = scrolling(controlsPage)
button(controls, "Observe mode", function() request("/v1/config/update", "POST", { sunc_mode = "observe" }) end)
button(controls, "Mock mode", function() request("/v1/config/update", "POST", { sunc_mode = "mock" }) end)
for _, profile in { "high", "medium", "low", "potato" } do
	button(controls, "Profile: " .. profile, function() request("/v1/config/update", "POST", { active_profile = profile }) end)
end
button(controls, "Trigger diagnostics", function() request("/v1/diagnostics/trigger", "POST", {}) end)
button(controls, "Backup all sources", backupAll)
button(controls, "Rewrite all scripts", rewriteAll)

local fuzz = scrolling(fuzzerPage)
local remoteLabel = make("TextLabel", {
	Size = UDim2.new(1, -8, 0, 42), BackgroundColor3 = COLORS.button, BorderSizePixel = 0,
	Text = "Target: none", TextColor3 = COLORS.text, TextWrapped = true, Font = Enum.Font.Code, TextSize = 12,
}, fuzz) :: TextLabel
local schema = make("TextBox", {
	Size = UDim2.new(1, -8, 0, 150), BackgroundColor3 = COLORS.button, BorderSizePixel = 0,
	Text = "number:min=0,max=100\nstring:length=12", MultiLine = true, ClearTextOnFocus = false,
	TextColor3 = COLORS.text, Font = Enum.Font.Code, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, fuzz) :: TextBox
local rate = make("TextBox", { Size = UDim2.new(1, -8, 0, 34), BackgroundColor3 = COLORS.button, Text = tostring(fuzzerConfig.default_rate or 5), TextColor3 = COLORS.text, ClearTextOnFocus = false }, fuzz) :: TextBox
local duration = make("TextBox", { Size = UDim2.new(1, -8, 0, 34), BackgroundColor3 = COLORS.button, Text = tostring(fuzzerConfig.default_duration_seconds or 30), TextColor3 = COLORS.text, ClearTextOnFocus = false }, fuzz) :: TextBox
local fuzzResult = make("TextLabel", { Size = UDim2.new(1, -8, 0, 70), BackgroundColor3 = COLORS.panel, Text = "No active session", TextColor3 = COLORS.muted, TextWrapped = true }, fuzz) :: TextLabel

local function remoteSegments(remote: Instance): {string}
	local result = {}
	local current: Instance? = remote
	while current and current ~= game do table.insert(result, 1, current.Name) current = current.Parent end
	return result
end

local function parseSchema(text: string): ({any}?, string?)
	local result = {}
	for line in text:gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$") or ""
		if line == "" or line:sub(1, 1) == "#" then continue end
		if line:sub(1, 1) == "{" then
			local ok, value = pcall(function() return HttpService:JSONDecode(line) end)
			if not ok then return nil, "Invalid JSON descriptor" end
			table.insert(result, value)
			continue
		end
		local kind, optionsText = line:match("^([^:]+):?(.*)$")
		kind = string.lower(kind or "")
		local options: {[string]: any} = {}
		for key, value in (optionsText or ""):gmatch("([%w_]+)=([^,]+)") do options[string.lower(key)] = tonumber(value) or value end
		local descriptor
		if kind == "number" then descriptor = { __type = "RandomNumber", min = options.min or 0, max = options.max or 100 }
		elseif kind == "string" then descriptor = { __type = "RandomString", length = options.length or 12 }
		elseif kind == "boolean" then descriptor = { __type = "RandomBoolean" }
		elseif kind == "vector3" then descriptor = { __type = "RandomVector3", min = options.min or -100, max = options.max or 100 }
		elseif kind == "cframe" then descriptor = { __type = "RandomCFrame", min = options.min or -100, max = options.max or 100, maxRotationDegrees = options.maxrotation or options.maxrotationdegrees or 90 }
		elseif kind == "instance" then descriptor = { __type = "InstancePath", path = options.path or "" }
		elseif kind == "enumitem" then descriptor = { __type = "EnumItem", value = options.value or "" }
		else return nil, "Unsupported descriptor: " .. kind end
		table.insert(result, descriptor)
	end
	return result, nil
end

local function refreshRemotes()
	for _, child in fuzz:GetChildren() do if child.Name == "RemoteChoice" then child:Destroy() end end
	for _, remote in game:GetDescendants() do
		if (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction")) and not excluded(remote) then
			local choice = button(fuzz, remote:GetFullName(), function()
				selectedRemote = remote
				remoteLabel.Text = "Target: " .. remote:GetFullName()
			end)
			choice.Name = "RemoteChoice"
		end
	end
end

button(fuzz, "Refresh remote list", refreshRemotes)
button(fuzz, "Start fuzzing", function()
	if not selectedRemote then status.Text = "Select a remote" return end
	local args, parseError = parseSchema(schema.Text)
	if not args then status.Text = tostring(parseError) return end
	local ok, response = request("/v1/fuzz/start", "POST", {
		target = selectedRemote:GetFullName(), target_segments = remoteSegments(selectedRemote),
		target_class = selectedRemote.ClassName, arg_types = args,
		rate = tonumber(rate.Text), duration = tonumber(duration.Text),
	})
	if ok then activeSession = tostring(response.sessionId) fuzzResult.Text = "Queued: " .. activeSession
	else fuzzResult.Text = tostring(response) end
end)
button(fuzz, "Stop fuzzing", function()
	if activeSession then request("/v1/fuzz/stop/" .. HttpService:UrlEncode(activeSession), "POST", {}) end
end)
refreshRemotes()

local trafficRows: {GuiObject} = {}
local function addTraffic(event: any)
	sequence = math.max(sequence, tonumber(event.seq) or 0)
	local payload = event.payload
	local record = if typeof(payload) == "table" then payload.record or payload else payload
	local channel = if typeof(record) == "table" then tostring(record.channel or record.prefix or "TRACE") else "TRACE"
	local phase = if typeof(record) == "table" then tostring(record.phase or "") else ""
	local target = ""
	if typeof(record) == "table" then
		if typeof(record.remote) == "table" then target = tostring(record.remote.path or record.remote.name or "")
		else target = tostring(record.target or "") end
	end
	local row = make("TextLabel", {
		Size = UDim2.new(1, -8, 0, 38), BackgroundColor3 = COLORS.button, BorderSizePixel = 0,
		Text = string.format("[%s/%s] %s", channel, phase, target), TextColor3 = COLORS.text,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Enum.Font.Code, TextSize = 12,
	}, trafficList) :: TextLabel
	table.insert(trafficRows, row)
	while #trafficRows > 50 do table.remove(trafficRows, 1):Destroy() end
end

task.spawn(function()
	while true do
		task.wait(1)
		local ok, response = request("/v1/status", "GET", nil)
		status.Text = if ok then string.format("Bridge online · %s · %s", response.activeProfile, response.suncMode) else "Bridge offline"
		local trafficOk, traffic = request("/v1/traffic?after=" .. sequence .. "&limit=50", "GET", nil)
		if trafficOk and typeof(traffic.events) == "table" then for _, event in traffic.events do addTraffic(event) end end
		if activeSession then
			local fuzzOk, fuzzStatus = request("/v1/fuzz/status/" .. HttpService:UrlEncode(activeSession), "GET", nil)
			if fuzzOk and typeof(fuzzStatus.session) == "table" then
				local session = fuzzStatus.session
				fuzzResult.Text = string.format("%s · calls=%s · errors=%s · avg=%.2fms", session.status, session.calls, session.errors, session.averageLatencyMs or 0)
				if session.status ~= "queued" and session.status ~= "running" then activeSession = nil end
			end
		end
	end
end)

rewriteButton.Click:Connect(rewriteAll)
backupButton.Click:Connect(backupAll)
dashboardButton.Click:Connect(function() widget.Enabled = not widget.Enabled end)
toggleButton.Click:Connect(function()
	enabled = not enabled plugin:SetSetting("HarnessXEnabled", enabled) toggleButton:SetActive(enabled)
end)
widget:BindToClose(function() widget.Enabled = false end)

if pluginConfig.auto_rewrite_on_save == true then
	ScriptEditorService.TextDocumentDidChange:Connect(function(document)
		if not enabled or document:IsCommandBar() then return end
		local target = document:GetScript()
		if not target or excluded(target) then return end
		task.delay(1.25, function()
			if enabled and target.Parent then updateScript(target, function(source) return (rewriteSource(source)) end) end
		end)
	end)
end

show("Traffic")
refreshScripts()
print("HarnessX Studio plugin loaded")

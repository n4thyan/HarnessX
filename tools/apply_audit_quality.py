from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(
        pattern,
        lambda _match: replacement,
        text,
        count=1,
        flags=re.S,
    )
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return updated


plugin_path = ROOT / "roblox" / "Plugin.lua"
plugin = plugin_path.read_text(encoding="utf-8")

plugin = replace_once(
    plugin,
    'local pluginConfig = if typeof(bridgeConfig.plugin) == "table" then bridgeConfig.plugin else {}\nlocal fuzzerConfig = if typeof(bridgeConfig.fuzzer) == "table" then bridgeConfig.fuzzer else {}\n',
    '''local pluginConfig = if typeof(bridgeConfig.plugin) == "table" then bridgeConfig.plugin else {}
if pluginConfig.enabled == false then
\twarn("HarnessX plugin is disabled by config.json")
\treturn nil
end
local fuzzerConfig = if typeof(bridgeConfig.fuzzer) == "table" then bridgeConfig.fuzzer else {}
''',
    "plugin enabled setting",
)

masking = r'''local function skipQuotedString(source: string, index: number): number
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
end'''

plugin = regex_once(
    plugin,
    r"local function skipString\(source: string, index: number\): number.*?local function codeMask\(source: string\): string.*?\nend\n\nlocal function receiverStart",
    masking + "\n\nlocal function receiverStart",
    "Luau masking",
)

rewrite = r'''local function prependInstrumentationHeader(source: string, header: string): string
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
end'''

plugin = regex_once(
    plugin,
    r"local function rewriteSource\(source: string\): \(string, number\).*?\nend\n\nlocal function updateScript",
    rewrite + "\n\nlocal function updateScript",
    "source rewriter",
)

backup = r'''local function instancePathSegments(instance: Instance): {string}
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
end'''

plugin = regex_once(
    plugin,
    r"local function backupAll\(\).*?\nend\n\nlocal function injectTrace",
    backup + "\n\nlocal function injectTrace",
    "backup payload",
)

trace_helpers = r'''local function matchingParen(mask: string, open: number): number?
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
		local _, tailEnd = tail:find("^%s*:%s*(FireServer|InvokeServer)%s*%(")
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
end'''

plugin = regex_once(
    plugin,
    r"local function injectTrace\(target: Instance\).*?\nend\n\nlocal function refreshScripts",
    trace_helpers + "\n\nlocal function refreshScripts",
    "trace injection",
)

plugin = replace_once(
    plugin,
    'elseif kind == "cframe" then descriptor = { __type = "RandomCFrame", min = options.min or -100, max = options.max or 100 }',
    'elseif kind == "cframe" then descriptor = { __type = "RandomCFrame", min = options.min or -100, max = options.max or 100, maxRotationDegrees = options.maxrotation or options.maxrotationdegrees or 90 }',
    "CFrame rotation option",
)

plugin_path.write_text(plugin, encoding="utf-8", newline="\n")

# Documentation updates.
readme_path = ROOT / "README.md"
readme = readme_path.read_text(encoding="utf-8")
readme = readme.replace(
    "Install Python dependencies:\n\n```bat\npip install flask psutil\n```",
    "HarnessX requires Python 3.10 or newer. Install the pinned direct dependencies:\n\n```bat\npip install -r requirements.lock\n```",
)
readme = regex_once(
    readme,
    r"Set a local bridge token of at least 16 characters in `config.json`:.*?The authenticated `/v1/config` route cannot supply its own authentication token because a caller already needs the token to access that route\.",
    '''On first start, the bridge replaces the committed placeholder token with a random token and writes it to `config.json`. You can instead supply `HARNESSX_BRIDGE_TOKEN` as an environment variable. The bridge refuses to continue with an invalid token.

Set the same token in Studio from the Command Bar before loading Core or the plugin:

```lua
game:SetAttribute("HarnessXEnabled", true)
game:SetAttribute("HarnessXBridgeToken", "copy-the-token-from-config-json")
```

`HarnessXEnabled` is an additional Studio opt-in and never bypasses `RunService:IsStudio()`. The token protects the loopback HTTP service from unrelated local processes, but code already executing inside the same Studio DataModel can read attributes and use HarnessX transport remotes. Do not run untrusted place code while HarnessX is enabled.

The bridge intentionally rejects browser-origin requests and does not emit permissive CORS headers. Do not add `flask-cors` or wildcard origins for convenience.''',
    "README token and CORS guidance",
)
readme = readme.replace(
    "Open the target selector and choose a remote. The plugin performs a heuristic source scan to estimate its argument count. Direct method calls and rewritten `UNC.FireServer()` / `SUNC.InvokeServer()` calls are both considered.\n\nArgument detection cannot resolve every dynamically generated remote reference. The schema editor remains authoritative.",
    "Open the target selector and choose a remote, then define the argument schema explicitly. HarnessX does not infer a reliable remote contract from source code; the schema editor is authoritative.",
)
if "## Runtime resilience" not in readme:
    readme += '''

## Runtime resilience

The Core traffic queue is bounded. When the configured limit is reached, the oldest queued record is dropped and the dropped-record count is reported in runtime status. Failed bridge batches are retried with bounded exponential backoff; they are discarded after the configured retry cap.

SUNC profiling reports `remoteDurationMs`, `preflightDurationMs`, and `totalDurationMs`. The compatibility field `durationMs` now represents only the target RemoteFunction call. Observe mode no longer blocks the game call on the localhost preflight. Mock and fuzz modes retain synchronous preflight because they may change behavior.

The AutoProxy quick-start table is created in `Fuzzer.client.lua`, where client-to-server remote methods are valid. It is available as `_G.HarnessXRemotes` in that client Luau VM when `ReplicatedStorage.Remotes` exists.
'''
readme_path.write_text(readme.rstrip() + "\n", encoding="utf-8", newline="\n")

status_path = ROOT / "CURRENT_STATUS.md"
status = status_path.read_text(encoding="utf-8")
if "## Audit remediation" not in status:
    status += '''

## Audit remediation

- Default bridge credentials are replaced on first start or supplied through `HARNESSX_BRIDGE_TOKEN`.
- Browser origins and CORS preflights are rejected.
- Runtime traffic is rate-limited, size-limited, bounded, and retried with a fixed cap.
- SUNC latency separates target-remote time from HarnessX preflight overhead.
- Source auto-rewrite is disabled by default and the rewriter masks quoted strings, long strings, line comments, and block comments.
- Backups use path-segment arrays and deterministic collision suffixes.
- Completed fuzz sessions are retained in a bounded history.
- CI performs Python tests and repository security-contract checks.

A Roblox Studio playtest is still required to validate Luau behavior and DockWidget rendering.
'''
status_path.write_text(status.rstrip() + "\n", encoding="utf-8", newline="\n")

validation_path = ROOT / "VALIDATION.md"
validation = validation_path.read_text(encoding="utf-8")
if "Automated on every push" not in validation:
    validation += '''

Automated on every push and pull request:
- Python syntax compilation
- Encoder round trips
- Flask authentication checks
- Browser-origin and CORS regression checks
- Disabled memory endpoint check
- Studio guard and configuration contract checks
- Current-tree scan for unsupported process-memory and engine-hook APIs
'''
validation_path.write_text(validation.rstrip() + "\n", encoding="utf-8", newline="\n")

# Tests.
tests = ROOT / "tests"
tests.mkdir(exist_ok=True)
(tests / "test_encoder.py").write_text('''from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

from encoder import decode, encode


class EncoderTests(unittest.TestCase):
    def test_round_trips(self) -> None:
        value = {"kind": "test", "payload": [True, 12, "héllo", {"x": 1}]}
        for rounds in (1, 2, 3, 4, 16):
            with self.subTest(rounds=rounds):
                self.assertEqual(decode(encode(value, rounds, nonce_ms=123456)), value)


if __name__ == "__main__":
    unittest.main()
''', encoding="utf-8", newline="\n")

(tests / "test_bridge_security.py").write_text('''from __future__ import annotations

import importlib
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ["HARNESSX_BRIDGE_TOKEN"] = "test-token-that-is-long-enough"
os.environ["HARNESSX_DISABLE_SCANNER"] = "1"
sys.path.insert(0, str(ROOT / "server"))

main = importlib.import_module("main")


class BridgeSecurityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = main.app.test_client()
        self.headers = {"X-Debug-Token": os.environ["HARNESSX_BRIDGE_TOKEN"]}

    def test_v1_requires_token(self) -> None:
        self.assertEqual(self.client.get("/v1/health").status_code, 401)
        self.assertEqual(self.client.get("/v1/health", headers=self.headers).status_code, 200)

    def test_browser_origins_are_rejected_without_cors_headers(self) -> None:
        headers = dict(self.headers)
        headers["Origin"] = "https://example.invalid"
        response = self.client.get("/v1/status", headers=headers)
        self.assertEqual(response.status_code, 403)
        self.assertNotIn("Access-Control-Allow-Origin", response.headers)

    def test_options_is_not_a_cors_bypass(self) -> None:
        response = self.client.options("/v1/status", headers=self.headers)
        self.assertEqual(response.status_code, 405)
        self.assertNotIn("Access-Control-Allow-Origin", response.headers)

    def test_memory_read_remains_disabled(self) -> None:
        response = self.client.post("/v1/memory/read", headers=self.headers)
        self.assertEqual(response.status_code, 403)

    def test_config_does_not_return_token(self) -> None:
        response = self.client.get("/v1/config", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("token", response.get_json())


if __name__ == "__main__":
    unittest.main()
''', encoding="utf-8", newline="\n")

(tests / "test_repository_contract.py").write_text('''from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RepositoryContractTests(unittest.TestCase):
    def test_all_luau_entry_points_have_both_guards(self) -> None:
        expected = [
            'if not game:GetService("RunService"):IsStudio() then return nil end',
            'if game:GetAttribute("HarnessXEnabled") ~= true',
        ]
        for path in sorted((ROOT / "roblox").glob("*.lua")):
            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines[0], expected[0], path.name)
            self.assertTrue(lines[1].startswith(expected[1]), path.name)

    def test_safe_configuration_defaults(self) -> None:
        config = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(config["bridge"]["host"], "127.0.0.1")
        self.assertFalse(config["plugin"]["auto_rewrite_on_save"])
        self.assertGreaterEqual(config["runtime"]["max_pending_events"], 1)

    def test_current_tree_has_no_unsupported_runtime_apis(self) -> None:
        forbidden = (
            "ReadProcessMemory",
            "WriteProcessMemory",
            "OpenProcess(",
            "ctypes.windll",
            "hookmetamethod",
            "getrawmetatable",
            "flask_cors",
            "CORS(app",
        )
        for path in list((ROOT / "server").glob("*.py")) + list((ROOT / "roblox").glob("*.lua")):
            source = path.read_text(encoding="utf-8")
            for term in forbidden:
                self.assertNotIn(term, source, f"{term} in {path}")
        self.assertFalse((ROOT / "EXECUTOR_BUILD.md").exists())

    def test_rewriter_regression_markers_exist(self) -> None:
        source = (ROOT / "roblox" / "Plugin.lua").read_text(encoding="utf-8")
        self.assertIn("longBracketEnd", source)
        self.assertIn("prependInstrumentationHeader", source)
        self.assertIn("alreadyProxy", source)
        self.assertIn("traceInstrumentedCalls", source)


if __name__ == "__main__":
    unittest.main()
''', encoding="utf-8", newline="\n")

workflow = ROOT / ".github" / "workflows" / "ci.yml"
workflow.parent.mkdir(parents=True, exist_ok=True)
workflow.write_text('''name: HarnessX CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
      - run: python -m pip install --upgrade pip
      - run: python -m pip install -r requirements.lock
      - run: python -m compileall -q server tests
      - run: python -m json.tool config.json >/dev/null
      - run: python -m unittest discover -s tests -v
        env:
          HARNESSX_BRIDGE_TOKEN: ci-token-that-is-long-enough
          HARNESSX_DISABLE_SCANNER: "1"
''', encoding="utf-8", newline="\n")

# Remove transient branch trigger if present.
(ROOT / ".audit-remediation-trigger").unlink(missing_ok=True)

# Structural sanity checks before the workflow runs the real tests.
assert "alreadyProxy" in plugin
assert "longBracketEnd" in plugin
assert "maxRotationDegrees" in plugin
assert "auto_rewrite_on_save" in (ROOT / "config.json").read_text(encoding="utf-8")

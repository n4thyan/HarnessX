from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
plugin_path = ROOT / "roblox" / "Plugin.lua"
plugin = plugin_path.read_text(encoding="utf-8")
old = '''\t\tlocal tail = mask:sub(wrapFinish + 1)
\t\tlocal _, tailEnd = tail:find("^%s*:%s*(FireServer|InvokeServer)%s*%(")
\t\tif tailEnd ~= nil then
'''
new = '''\t\tlocal tail = mask:sub(wrapFinish + 1)
\t\tlocal _, fireEnd = tail:find("^%s*:%s*FireServer%s*%(")
\t\tlocal _, invokeEnd = tail:find("^%s*:%s*InvokeServer%s*%(")
\t\tlocal tailEnd = fireEnd or invokeEnd
\t\tif tailEnd ~= nil then
'''
if plugin.count(old) != 1:
    raise SystemExit("RemoteProxy trace pattern: expected one match")
plugin = plugin.replace(old, new, 1)
plugin_path.write_text(plugin, encoding="utf-8", newline="\n")

contract_path = ROOT / "tests" / "test_repository_contract.py"
contract = contract_path.read_text(encoding="utf-8")
needle = '        self.assertIn("traceInstrumentedCalls", source)\n'
replacement = needle + '        self.assertNotIn("FireServer|InvokeServer", source)\n'
if replacement not in contract:
    if contract.count(needle) != 1:
        raise SystemExit("trace regression assertion marker missing")
    contract = contract.replace(needle, replacement, 1)
contract_path.write_text(contract, encoding="utf-8", newline="\n")

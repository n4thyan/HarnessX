from __future__ import annotations

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
            "kernel32.ReadProcessMemory(",
            "kernel32.WriteProcessMemory(",
            "kernel32.OpenProcess(",
            "ctypes.windll.kernel32",
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
        self.assertNotIn("FireServer|InvokeServer", source)


if __name__ == "__main__":
    unittest.main()

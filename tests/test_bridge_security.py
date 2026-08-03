from __future__ import annotations

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

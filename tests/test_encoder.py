from __future__ import annotations

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

from __future__ import annotations

import json
import time
from typing import Any

MAX_ROUNDS = 16


class EncoderError(ValueError):
    """Raised when a transport envelope cannot be decoded safely."""


def _key_byte(nonce_byte: int, round_index: int, byte_index: int) -> int:
    # Luau indexes bytes from 1, so Python callers pass byte_index + 1.
    return (nonce_byte + round_index * 31 + byte_index * 17) % 256


def _transform(data: bytes, nonce_byte: int, rounds: int, *, decode: bool) -> bytes:
    output = data
    round_order = range(rounds, 0, -1) if decode else range(1, rounds + 1)

    for round_index in round_order:
        output = bytes(
            byte ^ _key_byte(nonce_byte, round_index, byte_index + 1)
            for byte_index, byte in enumerate(output)
        )

    return output


def encode(value: Any, rounds: int = 3, *, nonce_ms: int | None = None) -> str:
    if not isinstance(rounds, int) or not 1 <= rounds <= MAX_ROUNDS:
        raise EncoderError(f"rounds must be an integer from 1 to {MAX_ROUNDS}")

    nonce = int(time.time() * 1000) if nonce_ms is None else int(nonce_ms)
    payload = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    transformed = _transform(payload, nonce % 256, rounds, decode=False)

    return json.dumps(
        {
            "version": 1,
            "algorithm": "rolling-xor-hex",
            "nonce": nonce,
            "rounds": rounds,
            "data": transformed.hex(),
        },
        separators=(",", ":"),
    )


def decode(envelope_text: str) -> Any:
    try:
        envelope = json.loads(envelope_text)
    except json.JSONDecodeError as exc:
        raise EncoderError("Envelope is not valid JSON") from exc

    if not isinstance(envelope, dict):
        raise EncoderError("Envelope must be a JSON object")
    if envelope.get("version") != 1:
        raise EncoderError("Unsupported envelope version")
    if envelope.get("algorithm") != "rolling-xor-hex":
        raise EncoderError("Unsupported envelope algorithm")

    nonce = envelope.get("nonce")
    rounds = envelope.get("rounds")
    data_hex = envelope.get("data")

    if not isinstance(nonce, int):
        raise EncoderError("nonce must be an integer")
    if not isinstance(rounds, int) or not 1 <= rounds <= MAX_ROUNDS:
        raise EncoderError(f"rounds must be an integer from 1 to {MAX_ROUNDS}")
    if not isinstance(data_hex, str):
        raise EncoderError("data must be a hexadecimal string")
    if len(data_hex) % 2 != 0:
        raise EncoderError("hexadecimal data has an odd length")

    try:
        transformed = bytes.fromhex(data_hex)
    except ValueError as exc:
        raise EncoderError("data is not valid hexadecimal") from exc

    decoded = _transform(transformed, nonce % 256, rounds, decode=True)

    try:
        return json.loads(decoded.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EncoderError("Decoded data is not valid UTF-8 JSON") from exc

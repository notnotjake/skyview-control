#!/usr/bin/env python3
"""SkyView DPS 51 encoder.

Ported from work/tuya-docker/dps51. The DPS 51 payload is base64 of 12 bytes:
    bytes([mode, preset]) + struct.pack(">5H", *fields)
with mode=2, preset=31 for the standard channel-mix command.
"""
import base64
import struct


def encode(mode: int, preset: int, fields: list[int]) -> str:
    """Encode a DPS 51 payload to base64. Raises ValueError on invalid input."""
    if len(fields) != 5:
        raise ValueError("DPS 51 payload needs exactly five 16-bit fields")

    for value in (mode, preset):
        if not 0 <= value <= 255:
            raise ValueError("mode and preset must fit in one byte: 0-255")
    for value in fields:
        if not 0 <= value <= 65535:
            raise ValueError("field values must fit in two bytes: 0-65535")

    raw = bytes([mode, preset]) + struct.pack(">5H", *fields)
    return base64.b64encode(raw).decode("ascii")


if __name__ == "__main__":
    # Minimal debugging helper: encode <mode> <preset> <f1> <f2> <f3> <f4> <f5>
    import sys

    args = [int(a) for a in sys.argv[1:]]
    if len(args) != 7:
        raise SystemExit("usage: dps51.py <mode> <preset> <f1> <f2> <f3> <f4> <f5>")
    print(encode(args[0], args[1], args[2:]))

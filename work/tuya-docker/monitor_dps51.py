import ast
import base64
import binascii
import datetime as dt
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path


PAYLOAD_RE = re.compile(r"Received Payload:\s*(\{.*\})")


def strip_quotes(value: str) -> str:
    return value.strip().strip("\"'")


def decode_dps51(payload: str) -> dict:
    raw = base64.b64decode(payload, validate=True)
    decoded = {
        "payload": payload,
        "hex": raw.hex(),
        "length": len(raw),
    }

    if len(raw) == 12:
        decoded["mode"] = raw[0]
        decoded["preset"] = raw[1]
        decoded["fields"] = list(struct.unpack(">5H", raw[2:]))

    return decoded


def main() -> int:
    device_id = strip_quotes(os.environ["TUYA_DEVICE_ID"])
    ip = strip_quotes(os.environ.get("TUYA_OVERRIDE_IP") or os.environ["TUYA_DEVICE_IP"])
    version = strip_quotes(os.environ.get("TUYA_VERSION", "3.4"))
    log_file = Path(os.environ.get("TUYA_DPS51_LOG", "/data/dps51-events.jsonl"))

    cmd = [
        "python",
        "-m",
        "tinytuya",
        "monitor",
        "--id",
        device_id,
        "--ip",
        ip,
        "--version",
        version,
    ]

    print(f"Monitoring DPS 51 for {device_id} at {ip} (version {version})")
    print(f"Appending events to {log_file}")
    print("Use the app to change lamp states. Press Ctrl-C when done.")

    event_count = 0
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as process:
        assert process.stdout is not None
        try:
            for line in process.stdout:
                print(line, end="")
                match = PAYLOAD_RE.search(line)
                if not match:
                    continue

                try:
                    payload = ast.literal_eval(match.group(1))
                except (SyntaxError, ValueError):
                    continue

                dps = payload.get("dps") or payload.get("data", {}).get("dps") or {}
                if "51" not in dps:
                    continue

                try:
                    decoded = decode_dps51(dps["51"])
                except (binascii.Error, ValueError):
                    continue

                event_count += 1
                event = {
                    "event": event_count,
                    "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
                    **decoded,
                }
                with log_file.open("a") as file:
                    file.write(json.dumps(event, separators=(",", ":")) + "\n")

                fields = event.get("fields")
                print(f"\nDPS51 event {event_count}: preset={event.get('preset')} fields={fields} payload={event['payload']}\n")
        except KeyboardInterrupt:
            process.terminate()
            return 0

    return process.returncode or 0


if __name__ == "__main__":
    raise SystemExit(main())

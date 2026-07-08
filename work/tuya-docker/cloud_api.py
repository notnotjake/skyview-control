import argparse
import json
import os
import struct
import base64
import sys

import tinytuya


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value.strip().strip("\"'")


def make_cloud() -> tinytuya.Cloud:
    return tinytuya.Cloud(
        apiRegion=env("TUYA_REGION"),
        apiKey=env("TUYA_ACCESS_ID"),
        apiSecret=env("TUYA_ACCESS_SECRET"),
        apiDeviceID=env("TUYA_DEVICE_ID"),
    )


def dps51_payload(mode: int, preset: int, fields: list[int]) -> str:
    raw = bytes([mode, preset]) + struct.pack(">5H", *fields)
    return base64.b64encode(raw).decode("ascii")


def print_json(data) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def cmd_status(args: argparse.Namespace) -> None:
    print_json(make_cloud().getstatus(env("TUYA_DEVICE_ID")))


def cmd_functions(args: argparse.Namespace) -> None:
    print_json(make_cloud().getfunctions(env("TUYA_DEVICE_ID")))


def cmd_send(args: argparse.Namespace) -> None:
    value = args.value
    try:
        value = json.loads(args.value)
    except json.JSONDecodeError:
        pass

    payload = {"commands": [{"code": args.code, "value": value}]}
    print_json(make_cloud().sendcommand(env("TUYA_DEVICE_ID"), payload))


def cmd_set_dps51(args: argparse.Namespace) -> None:
    payload = dps51_payload(args.mode, args.preset, args.fields)
    commands = {"commands": [{"code": args.code, "value": payload}]}
    print(f"payload={payload}", file=sys.stderr)
    print_json(make_cloud().sendcommand(env("TUYA_DEVICE_ID"), commands))


def main() -> int:
    parser = argparse.ArgumentParser(description="Tuya Cloud test helper for SkyView lamp")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status")
    status.set_defaults(func=cmd_status)

    functions = subparsers.add_parser("functions")
    functions.set_defaults(func=cmd_functions)

    send = subparsers.add_parser("send")
    send.add_argument("code")
    send.add_argument("value")
    send.set_defaults(func=cmd_send)

    dps51 = subparsers.add_parser("set-dps51")
    dps51.add_argument("--code", default="51")
    dps51.add_argument("mode", type=int)
    dps51.add_argument("preset", type=int)
    dps51.add_argument("fields", type=int, nargs=5)
    dps51.set_defaults(func=cmd_set_dps51)

    args = parser.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

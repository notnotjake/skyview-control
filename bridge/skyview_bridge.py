#!/usr/bin/env python3
"""SkyView bridge service.

Single asyncio process that connects to the relay over WebSocket, reports lamp
reachability via heartbeats, and applies channel-mix commands to a Tuya lamp
(DPS 51) via tinytuya.

All tinytuya calls are blocking and are therefore run in threads. A fresh
tinytuya.Device is created per command/poll (connections are cheap and flaky to
keep open). Commands serialize through an asyncio.Lock so the heartbeat/poll
loops never block on lamp I/O.
"""
import asyncio
import json
import logging
import os
import random
import signal
import sys
from datetime import datetime, timezone

import tinytuya
import websockets

import dps51

BRIDGE_ID = "skyview-bridge"
VERSION = "0.1.0"
HEARTBEAT_INTERVAL = 20
POLL_INTERVAL = 30
SOCKET_TIMEOUT = 5
COMMAND_TIMEOUT = 12  # must stay under the relay's 15s command window
BACKOFF_INITIAL = 1
BACKOFF_MAX = 60
STABLE_CONNECTION = 60  # a connection living longer than this resets backoff

REQUIRED_ENV = [
    "RELAY_URL",
    "BRIDGE_TOKEN",
    "TUYA_DEVICE_ID",
    "TUYA_LOCAL_KEY",
    "TUYA_DEVICE_IP",
]

log = logging.getLogger("skyview-bridge")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Config:
    def __init__(self) -> None:
        missing = [name for name in REQUIRED_ENV if not os.environ.get(name)]
        if missing:
            raise SystemExit(
                "Missing required environment variables: " + ", ".join(missing)
            )
        self.relay_url = os.environ["RELAY_URL"]
        self.token = os.environ["BRIDGE_TOKEN"]
        self.device_id = os.environ["TUYA_DEVICE_ID"]
        self.local_key = os.environ["TUYA_LOCAL_KEY"]
        self.device_ip = os.environ["TUYA_DEVICE_IP"]
        self.version = float(os.environ.get("TUYA_VERSION", "3.4"))


class State:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.lamp_reachable = False
        self.command_lock = asyncio.Lock()


def make_device(config: Config) -> "tinytuya.Device":
    d = tinytuya.Device(
        config.device_id,
        config.device_ip,
        config.local_key,
        version=config.version,
    )
    d.set_socketTimeout(SOCKET_TIMEOUT)
    return d


# --- blocking tinytuya operations (run via asyncio.to_thread) ---------------


def poll_lamp(config: Config) -> bool:
    """Return True iff the lamp responds with a dict containing 'dps'."""
    try:
        d = make_device(config)
        status = d.status()
        return isinstance(status, dict) and "dps" in status
    except Exception:
        return False


def apply_command(config: Config, payload_b64: str) -> None:
    """Run the proven lamp command sequence. Raises on failure.

    tinytuya does not raise on failure; it returns a dict with an 'Error' key.
    """
    d = make_device(config)
    for dp, value in ((21, "colour"), (51, payload_b64)):
        response = d.set_value(dp, value)
        if isinstance(response, dict) and response.get("Error"):
            raise RuntimeError(f"set dps {dp} failed: {response['Error']}")


# --- async loops ------------------------------------------------------------


async def lamp_poll_loop(state: State) -> None:
    while True:
        reachable = await asyncio.to_thread(poll_lamp, state.config)
        if reachable != state.lamp_reachable:
            state.lamp_reachable = reachable
            log.info("lamp poll state change: reachable=%s", reachable)
        await asyncio.sleep(POLL_INTERVAL)


async def heartbeat_loop(state: State, ws) -> None:
    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL)
        msg = {
            "type": "heartbeat",
            "lampReachable": state.lamp_reachable,
            "lampIp": state.config.device_ip,
            "ts": now_iso(),
        }
        await ws.send(json.dumps(msg))


async def handle_command(state: State, ws, message: dict) -> None:
    cmd_id = message.get("id")
    payload = message.get("payload") or {}
    log.info("command received: id=%s action=%s", cmd_id, message.get("action"))

    error = None
    async with state.command_lock:
        try:
            fields = payload["fields"]
            mode = payload.get("mode", 2)
            preset = payload.get("preset", 31)
            payload_b64 = dps51.encode(mode, preset, fields)
            await asyncio.wait_for(
                asyncio.to_thread(apply_command, state.config, payload_b64),
                timeout=COMMAND_TIMEOUT,
            )
        except asyncio.TimeoutError:
            error = "lamp command timed out (lamp unreachable?)"
        except Exception as exc:  # noqa: BLE001 - report any failure to relay
            error = str(exc) or exc.__class__.__name__

    ok = error is None
    result = {
        "type": "result",
        "id": cmd_id,
        "ok": ok,
        "error": error,
        "lampReachable": state.lamp_reachable,
    }
    await ws.send(json.dumps(result))
    log.info("command result: id=%s ok=%s error=%s", cmd_id, ok, error)


async def receive_loop(state: State, ws) -> None:
    async for raw in ws:
        try:
            message = json.loads(raw)
        except (ValueError, TypeError):
            log.warning("ignoring non-JSON message")
            continue
        msg_type = message.get("type")
        if msg_type == "command":
            # Spawn so a running (locked) command does not block further reads.
            asyncio.create_task(handle_command(state, ws, message))
        else:
            log.info("ignoring unknown message type: %s", msg_type)


async def uplink_session(state: State) -> None:
    """One connection lifecycle. Raises on disconnect/error to trigger reconnect."""
    config = state.config
    async with websockets.connect(
        config.relay_url,
        additional_headers={"Authorization": f"Bearer {config.token}"},
    ) as ws:
        log.info("connected to relay: %s", config.relay_url)
        hello = {
            "type": "hello",
            "bridgeId": BRIDGE_ID,
            "version": VERSION,
            "lampIp": config.device_ip,
            "lampReachable": state.lamp_reachable,
        }
        await ws.send(json.dumps(hello))

        heartbeat = asyncio.create_task(heartbeat_loop(state, ws))
        receive = asyncio.create_task(receive_loop(state, ws))
        try:
            done, pending = await asyncio.wait(
                {heartbeat, receive}, return_when=asyncio.FIRST_COMPLETED
            )
        finally:
            heartbeat.cancel()
            receive.cancel()
            await asyncio.gather(heartbeat, receive, return_exceptions=True)
        # Surface whichever task ended so the outer loop reconnects.
        for task in done:
            task.result()


async def uplink_loop(state: State) -> None:
    backoff = BACKOFF_INITIAL
    while True:
        started = asyncio.get_event_loop().time()
        try:
            await uplink_session(state)
            log.info("relay connection closed")
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - any error -> reconnect
            log.info("relay connection lost: %s", exc)

        lived = asyncio.get_event_loop().time() - started
        if lived > STABLE_CONNECTION:
            backoff = BACKOFF_INITIAL

        jitter = backoff * 0.25
        delay = backoff + random.uniform(-jitter, jitter)
        delay = max(0.0, delay)
        log.info("reconnecting in %.1fs", delay)
        await asyncio.sleep(delay)
        backoff = min(backoff * 2, BACKOFF_MAX)


async def main() -> None:
    config = Config()
    logging.basicConfig(
        level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    log.info("starting bridge %s version %s", BRIDGE_ID, VERSION)

    state = State(config)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:  # pragma: no cover - non-unix
            pass

    poll = asyncio.create_task(lamp_poll_loop(state))
    uplink = asyncio.create_task(uplink_loop(state))

    await stop.wait()
    log.info("shutdown signal received, stopping")
    for task in (poll, uplink):
        task.cancel()
    await asyncio.gather(poll, uplink, return_exceptions=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        pass
    sys.exit(0)

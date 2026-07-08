# SkyView Control — MVP Spec

This is the implementation contract for the MVP. Both services implement exactly this; see DESIGN.md for the broader direction.

MVP surface: one command type (channel mix → DPS 51), bridge connectivity status, and the install flow. No database, no schedules, no history.

## Repo layout

```
bridge/                 # Python 3.12 asyncio service
  skyview_bridge.py     # single-file service
  dps51.py              # encoder (ported from work/tuya-docker/dps51)
  requirements.txt      # tinytuya==1.20.0, websockets>=15
  Dockerfile
relay/                  # Bun + Hono service (TypeScript)
  package.json
  src/index.ts          # entry: Hono app + Bun.serve with websocket handler
  src/hub.ts            # bridge socket registry + pending command correlation
  (structure beyond this is implementer's choice; keep it small)
install.sh              # interactive installer at repo root (relay serves it)
railway.json            # Railway config-as-code
.github/workflows/bridge-image.yml
```

## Shared conventions

- All WS messages are single JSON objects, one per WS text frame.
- Channel values and DPS 51 fields are integers `0–1000`.
- Timestamps are ISO 8601 UTC strings.

## The lamp command (proven path — do not deviate)

To apply a channel mix, the bridge does, via tinytuya:

```python
d = tinytuya.Device(TUYA_DEVICE_ID, TUYA_DEVICE_IP, TUYA_LOCAL_KEY, version=float(TUYA_VERSION))
d.set_socketTimeout(5)
d.set_value(21, "colour")          # work_mode must be colour first
d.set_value(51, payload_b64)       # then the DPS 51 payload
```

`payload_b64` is base64 of 12 bytes: `bytes([mode, preset]) + struct.pack(">5H", *fields)` with `mode=2`, `preset=31`, `fields=[f1, f2, f3, f4, f5]`. Port the encoder from `work/tuya-docker/dps51` (encode function + validation) into `bridge/dps51.py`.

Channel-to-field mapping (relay owns this mapping; the bridge just takes fields):

| API channel | DPS 51 field | meaning |
|---|---|---|
| (none) | f1 | no visible effect, always 0 |
| `blue` | f2 | blue/top LED |
| `white` | f3 | warm-white low LED |
| `warm` | f4 | warm/amber LED |
| `red` | f5 | red LED |

Reachability poll: `d.status()`; reachable iff it returns a dict containing `"dps"`. Poll on a fresh `tinytuya.Device` each time is fine (tinytuya connections are cheap and flaky to keep open); do NOT keep one Device across commands.

## WebSocket protocol (bridge ⇄ relay)

- URL: `RELAY_URL` env on bridge, e.g. `wss://host/bridge`.
- Auth: bridge sends header `Authorization: Bearer $BRIDGE_TOKEN`. Relay rejects the upgrade with 401 otherwise. (Relay reads it from the upgrade request headers.)
- On connect, bridge sends `hello` first. Relay treats the newest connection as canonical (an old zombie socket is closed when a new hello arrives).

Messages:

```jsonc
// bridge → relay, once after connect
{ "type": "hello", "bridgeId": "skyview-bridge", "version": "0.1.0",
  "lampIp": "192.168.100.191", "lampReachable": true }

// bridge → relay, every 20s
{ "type": "heartbeat", "lampReachable": true, "lampIp": "192.168.100.191",
  "ts": "2026-07-07T20:00:00Z" }

// relay → bridge
{ "type": "command", "id": "<uuid>", "action": "dps51",
  "payload": { "mode": 2, "preset": 31, "fields": [0, 0, 0, 551, 357] } }

// bridge → relay, in response to a command (id echoes the command id)
{ "type": "result", "id": "<uuid>", "ok": true, "error": null,
  "lampReachable": true }
// on failure: { "type": "result", "id": "...", "ok": false, "error": "human-readable reason", "lampReachable": false }
```

Unknown message types are ignored (logged) by both sides.

## Bridge behavior (`bridge/skyview_bridge.py`)

Single asyncio process. Env config (all required unless noted):

```
RELAY_URL           wss://.../bridge
BRIDGE_TOKEN
TUYA_DEVICE_ID
TUYA_LOCAL_KEY
TUYA_DEVICE_IP
TUYA_VERSION        default "3.4"
LOG_LEVEL           default "INFO", optional
```

- **Uplink loop**: connect to RELAY_URL with the auth header; send `hello`; then send `heartbeat` every 20s. On any disconnect/error, reconnect with exponential backoff: 1s doubling to 60s cap, ±25% jitter, reset after a connection that lived >60s.
- **Lamp poll**: every 30s, `status()` the lamp with a 5s socket timeout in a thread (`asyncio.to_thread` — tinytuya is blocking). Cache `lampReachable`; heartbeats report the cached value.
- **Command handling**: on `command` messages, run the tinytuya sequence in `asyncio.to_thread`, then send `result`. Commands run one at a time (a lock/queue); a second command arriving while one runs simply waits.
- Log one line per significant event (connect, disconnect, command, result, poll state change) to stdout. Never log BRIDGE_TOKEN or TUYA_LOCAL_KEY.
- Handle SIGTERM cleanly (close WS, exit 0).

`bridge/Dockerfile`: `python:3.12-slim`, install requirements, `CMD ["python", "-u", "skyview_bridge.py"]`. No pip cache. Container gets config purely from env.

## Relay behavior (`relay/`)

Bun + Hono. Env: `API_TOKEN`, `BRIDGE_TOKEN`, `PORT` (default 3000).

Endpoints:

- `GET /healthz` → `200 {"ok": true}` — no auth (Railway healthcheck).
- `GET /install.sh` → serves the repo-root `install.sh` file as `text/x-shellscript` — no auth. Resolve the path relative to the repo root (relay is started from repo root; see railway.json).
- `POST /api/lamp/mix` — auth required. Body: `{ "blue"?: int, "warm"?: int, "white"?: int, "red"?: int }`, each 0–1000, missing → 0, must be integers; reject anything else with 400 and a JSON error. Builds `fields = [0, blue, white, warm, red]`, sends a `command` (uuid id) to the bridge socket:
  - No bridge connected → `503 {"error": "bridge_offline"}`.
  - Result within 15s → `200 {"ok": true, "id": ..., "lampReachable": ...}` or, if `ok:false` from bridge, `502 {"error": ...}`.
  - Timeout → `504 {"error": "bridge_timeout"}`.
- `GET /api/status` — auth required. → `{ "bridgeConnected": bool, "bridgeVersion": str|null, "lastHeartbeatAt": iso|null, "lampReachable": bool|null, "lampIp": str|null }`.
- `GET /bridge` — WebSocket upgrade, requires `Authorization: Bearer $BRIDGE_TOKEN` header; 401 otherwise.

Auth for `/api/*`: `Authorization: Bearer $API_TOKEN`, constant-time comparison, `401 {"error":"unauthorized"}` otherwise. If `API_TOKEN` or `BRIDGE_TOKEN` env is missing/empty, refuse to start with a clear error.

Implementation notes:

- Use `createBunWebSocket` from `hono/bun` (or plain `Bun.serve` websocket config — implementer's choice, but auth must happen at upgrade time).
- Pending commands: `Map<id, {resolve, timer}>`; resolve on matching `result`; reject all pending if the bridge socket drops.
- Track a single bridge connection (last `hello` wins; close the previous socket).
- Mark bridge disconnected if no heartbeat for 60s even if the socket looks open.
- `package.json` scripts: `"start": "bun run src/index.ts"`, `"dev": "bun --watch run src/index.ts"`. TypeScript, no build step (Bun runs TS directly). Keep dependencies to `hono` only.

## railway.json (repo root)

Config-as-code for the relay service, deploying from the repo root so `install.sh` is available:

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build": { "builder": "NIXPACKS", "buildCommand": "bun install --cwd relay" },
  "deploy": {
    "startCommand": "bun run relay/src/index.ts",
    "healthcheckPath": "/healthz",
    "restartPolicyType": "ON_FAILURE"
  }
}
```

(Exact builder details may be adjusted during deploy; keep the healthcheck path and start command stable.)

## install.sh

Interactive, idempotent, safe under `curl | bash` (read from `/dev/tty` for prompts). Flow:

1. Detect OS (macOS/Linux) and arch; check `docker` exists and the daemon responds, with install hints if not.
2. Prompt (with defaults where possible): relay URL, `BRIDGE_TOKEN`, `TUYA_DEVICE_ID`, `TUYA_LOCAL_KEY`, `TUYA_DEVICE_IP`. If `~/.skyview/bridge.env` already exists, offer keep/reconfigure.
3. Write `~/.skyview/bridge.env` (mode 600) and `~/.skyview/docker-compose.yml`:
   - image `ghcr.io/notnotjake/skyview-bridge:latest`
   - `restart: unless-stopped`, `env_file: bridge.env`
   - `network_mode: host` on Linux only; memory limit 128m.
4. `docker compose -p skyview-bridge up -d --pull always`; if the image pull fails (e.g. GHCR package not public yet), fall back to cloning the repo shallowly to `~/.skyview/src` and building the image locally.
5. Wait up to 30s polling `docker logs` for a "connected" line; print success + the three useful commands (logs/restart/down).

## .github/workflows/bridge-image.yml

On push to `main` touching `bridge/**`: buildx, platforms `linux/amd64,linux/arm64`, push `ghcr.io/notnotjake/skyview-bridge:latest` (+ sha tag), `GITHUB_TOKEN` permissions `packages: write`.

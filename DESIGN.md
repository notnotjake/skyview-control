# SkyView Control — System Design

Three components, matching AGENTS.md, now made concrete:

```
┌──────────┐   HTTPS + Bearer    ┌───────────────┐   WebSocket (outbound   ┌──────────┐   Tuya 3.4    ┌──────┐
│ clients  │ ──────────────────▶ │ relay (Railway)│ ◀──────from home────── │  bridge   │ ────LAN────▶ │ lamp │
│ curl/iOS │                     │ Bun+Hono+SQLite│                        │ Pi / Mac  │              └──────┘
└──────────┘                     └───────────────┘                        └──────────┘
```

- **relay** — Bun + Hono on Railway. Owns the API, auth, SQLite (Drizzle), schedules, and history. Holds the WebSocket the bridge dials into.
- **bridge** — small Python + TinyTuya service in Docker on the LAN device (spare Mac now, Pi/Radxa later). Dials out to the relay, executes lamp commands, monitors the lamp, reports health.
- **app** — later. It's just another API client; nothing in the design changes for it.

## Why these choices

**Bridge stays Python.** The entire proven control surface (TinyTuya, protocol 3.4, the DPS 51 encoder) is Python. Rewriting the Tuya layer in TypeScript (tuyapi) would re-open protocol risk for zero user-visible gain. A single-process asyncio service in `python:3.12-slim` idles around 40–70 MB RSS — comfortable on 1 GB RAM alongside Docker itself.

**Relay is Bun + Hono + `bun:sqlite` + Drizzle.** Bun serves WebSockets natively and Hono's `upgradeWebSocket` works on Bun. Drizzle has a first-class `drizzle-orm/bun-sqlite` driver. SQLite lives on a Railway volume. (Note: Bun's `Bun.sql` API is Postgres; for SQLite the native driver is `bun:sqlite`, which is what Drizzle uses.)

**Bridge → relay is a persistent WebSocket, always dialed from home.** No inbound ports, no dynamic DNS, works behind eero NAT. Reconnect with jittered exponential backoff (1s → 60s cap).

## The bridge

One asyncio process, three loops:

1. **Uplink loop** — maintain the WS to the relay. On connect, send `hello` (bridge id, version, lamp config). Then heartbeat every 20 s.
2. **Lamp loop** — maintain the TinyTuya connection. Poll status every ~30 s (and after every command) so the relay always has fresh DPS state. Uses the existing DPS 51 encode/decode logic, lifted from `work/tuya-docker/dps51` and `set-dps51`.
3. **Command executor** — commands arrive over the WS, run against the lamp, and the result (ok/error + resulting DPS state) is sent back tagged with the command's id.

### Lamp discovery / IP drift

The lamp IP has already changed once (`192.168.4.21` → `192.168.100.191`), so this is real:

- Normal path: use the configured IP.
- If the lamp stops responding for N consecutive polls: rediscover.
  - **On Linux (Pi) with `network_mode: host`:** TinyTuya UDP broadcast discovery — fast and exact (matches by device ID).
  - **Fallback (macOS Docker, where UDP broadcast dies at the NAT):** TCP scan of the local subnet for port 6668, then confirm by device ID handshake — same approach as `work/tuya-docker/scan_tuya_port.py`.
- When the IP changes, the bridge updates its local config and reports the new IP upstream.

### Health reporting

Heartbeat payload (every 20 s):

```json
{
  "type": "heartbeat",
  "lampReachable": true,
  "lampIp": "192.168.100.191",
  "lastDps": { "20": true, "51": "Ah8D6APoA+gD6APo" },
  "bridgeUptimeSec": 86400,
  "lastCommandAt": "2026-07-07T20:00:00Z"
}
```

The relay stores `last_seen`, latest state, and derives status for clients: `online` / `bridge-online-lamp-unreachable` / `offline` (no heartbeat > 60 s).

### Bridge config

Single env file at `~/.skyview/bridge.env` (mounted into the container):

```sh
RELAY_URL=wss://skyview.up.railway.app/bridge
BRIDGE_TOKEN=...          # issued by the relay, authenticates the WS
TUYA_DEVICE_ID=eb14adaf5931de0d4b9ofl
TUYA_LOCAL_KEY=...
TUYA_DEVICE_IP=192.168.100.191   # starting hint; bridge keeps it updated
TUYA_VERSION=3.4
```

### Container

- Multi-arch image (`linux/amd64` + `linux/arm64`) built with `docker buildx`, published to GHCR — the exact same image runs on the Mac and the Pi.
- `restart: unless-stopped`, `network_mode: host` on Linux; bridged with the TCP-scan fallback on macOS.
- Memory limit `128m` in compose as a guard rail; it should never get near it.

## The relay

### API (all under Bearer-token auth)

```
POST /api/lamp/power        { "on": true }
POST /api/lamp/preset       { "name": "relaxing" }            # working|relaxing|reading|sleeping (+ user-saved)
POST /api/lamp/mix          { "blue": 0, "white": 0, "warm": 551, "red": 357 }   # 0–1000 each
POST /api/lamp/dps51        { "mode": 2, "preset": 31, "fields": [0,0,0,551,357] }  # raw escape hatch
GET  /api/lamp/state        latest known DPS state + freshness timestamp
GET  /api/status            bridge online?, lamp reachable?, last_seen, lamp IP
GET  /api/history?limit=50  recent commands + who/what issued them + results
GET/POST/DELETE /api/presets     user-saved named mixes
GET/POST/PATCH/DELETE /api/schedules
```

Command flow: API request → row in `commands` (status `pending`) → pushed over the WS → bridge acks with result → row updated → HTTP response returns the result (with a ~10 s timeout that returns `202 pending` if the bridge is slow, and `503` immediately if the bridge is offline).

`mix` is the friendly layer: it maps named channels to DPS 51 field positions (field 2 = blue/top, field 3 = white, field 4 = warm/amber, field 5 = red, per AGENTS.md) and always sends `mode=2, preset=31`. `dps51` keeps full raw access for experimentation.

### Auth

Deliberately minimal — this is a single-user system:

- `API_TOKEN` (long random string) for clients: `Authorization: Bearer ...`. Works from curl, Postman, and the future iOS app unchanged.
- `BRIDGE_TOKEN` (separate long random string) for the bridge WS handshake.
- Both are env vars on Railway. No users table, no sessions, nothing to maintain. If the iOS app ever needs multi-device tokens, that's an additive table later.

### WebSocket hub (`/bridge`)

- One bridge connection expected (design allows a map of bridge-id → socket, so a second lamp/bridge later is trivial).
- Message types: `hello`, `heartbeat`, `command`, `result`, `state` (unsolicited push when the bridge notices the lamp changed — e.g. someone used the vendor app).
- Every `command` carries a UUID; `result` echoes it. Pending commands time out server-side after 15 s → marked `failed:timeout`.

### Database (SQLite on a Railway volume, Drizzle + `bun:sqlite`)

```
commands   id, source (api|schedule), type, payload(json), status, result(json), created_at, completed_at
state_log  id, dps(json), lamp_ip, reported_at            # sampled, pruned to ~30 days
presets    id, name, mode, preset_byte, fields(json), created_at
schedules  id, name, cron_expr, command(json), enabled, last_run_at
bridge     id, name, last_seen, lamp_ip, version          # one row for now
```

### Scheduler

In-process: a `setInterval` tick every 30 s checks enabled schedules (cron expressions via a tiny cron parser, timezone-aware — America/New_York) against `last_run_at`, and enqueues commands through the exact same path the API uses. No extra service, no Redis. Fades/sunrise scenes come later as a schedule whose command is a fade the **bridge** interpolates locally (smoother, and doesn't chatter over the WAN).

## Installer — `curl | bash`

`install.sh` served by the relay itself at `GET /install.sh` (no auth), so setup is:

```sh
curl -fsSL https://skyview.up.railway.app/install.sh | bash
```

What it does, interactively:

1. Checks for Docker (points at OrbStack/Docker Desktop on macOS, `apt install docker.io` hint on Pi).
2. Prompts for relay URL (pre-filled), `BRIDGE_TOKEN`, device ID, local key, and lamp IP (offers to scan for it).
3. Writes `~/.skyview/bridge.env` and `~/.skyview/docker-compose.yml` (host networking on Linux, bridged on macOS — it detects the OS).
4. `docker compose up -d` and tails the log until the first successful heartbeat, then prints "✓ bridge online".

Re-running it is safe (idempotent; offers update vs. reconfigure). `skyview-bridge` compose project name so `docker compose logs/restart` are obvious.

## Repo layout

```
skyview-control/
  bridge/            # Python asyncio service + Dockerfile + compose template
  relay/             # Bun + Hono + Drizzle; serves API, WS hub, install.sh
  install/install.sh
  work/              # existing scratch tools, untouched — still useful for protocol digging
```

## Build order

1. **Bridge core** — long-running service: lamp loop + command executor, driven first by a tiny local debug HTTP endpoint (so it's testable on the Mac before the relay exists). Lift the DPS 51 encoder as-is.
2. **Relay core** — Hono API + WS hub + auth + Drizzle schema; command round-trip working end-to-end (curl → Railway → Mac → lamp).
3. **Health + history + state log** — heartbeats, `/api/status`, `/api/history`, unsolicited state pushes.
4. **Installer + multi-arch image** — GHCR publish, `install.sh`, tested on the Mac; ready for the Pi the day it arrives.
5. **Schedules + saved presets** — cron scheduler, presets CRUD.
6. **Later**: bridge-side fades, sunrise/sunset scenes, iOS app.

## 1 GB RAM budget (Pi / Radxa ZERO 3W)

| Thing | RSS |
|---|---|
| OS + dockerd/containerd | ~250–350 MB |
| Bridge container (python-slim, asyncio) | ~40–70 MB |
| Headroom | ~600 MB |

Comfortable. If it ever isn't, the escape hatch is running the bridge as a bare systemd service with a venv (the code doesn't care), but Docker should be fine.

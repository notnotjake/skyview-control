# skyview-control

Control a SkyView Pro / SkyView Light lamp without the vendor app.

The lamp only exposes its full light-channel control (hidden DPS 51) over the Tuya **local** LAN protocol — Tuya Cloud rejects it — so this project runs a tiny bridge on the lamp's network and relays commands to it from anywhere:

```
curl / iOS app ──HTTPS──▶ relay (Railway, Bun+Hono) ◀──outbound WebSocket── bridge (Docker, Pi/Mac) ──Tuya 3.4──▶ lamp
```

- **`relay/`** — Bun + Hono service on Railway. Bearer-token API for clients; WebSocket hub the bridge dials into. No inbound ports needed at home.
- **`bridge/`** — small Python + TinyTuya service in Docker on any always-on device on the lamp's Wi-Fi (a Raspberry Pi–class board with 1 GB RAM is plenty).
- **`work/`** — the reverse-engineering scratch tools and protocol notes that got us here.

See [DESIGN.md](DESIGN.md) for the full architecture and [SPEC-MVP.md](SPEC-MVP.md) for the exact protocol contract.

## Install the bridge

On the device that shares a network with the lamp (needs Docker):

```sh
curl -fsSL https://<your-relay-host>/install.sh | bash
```

The installer asks for the relay URL, bridge token, and the lamp's Tuya device ID / local key / IP, writes `~/.skyview/`, and starts the container (`restart: unless-stopped`). Re-run it any time to update or reconfigure.

## Use the API

```sh
# Set a channel mix (each channel 0–1000; omitted channels are 0)
curl -X POST https://<relay-host>/api/lamp/mix \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"warm": 551, "red": 357}'

# Check bridge/lamp health
curl https://<relay-host>/api/status -H "Authorization: Bearer $API_TOKEN"
```

## Develop

```sh
# relay
cd relay && bun install
API_TOKEN=dev BRIDGE_TOKEN=dev bun run dev

# bridge (against a local relay)
cd bridge && pip install -r requirements.txt
RELAY_URL=ws://localhost:3000/bridge BRIDGE_TOKEN=dev \
  TUYA_DEVICE_ID=... TUYA_LOCAL_KEY=... TUYA_DEVICE_IP=... \
  python skyview_bridge.py
```

The relay deploys to Railway via `railway.json` (config-as-code); the bridge image is built multi-arch (amd64 + arm64) to `ghcr.io/notnotjake/skyview-bridge` by GitHub Actions on pushes to `bridge/**`.

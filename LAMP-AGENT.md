# SkyView Lamp — Agent Instructions

You can control a lamp through a simple HTTP API. Follow these instructions exactly.

## Setup

- Base URL: `https://relay-production-ce8a.up.railway.app`
- Every request needs this header: `Authorization: Bearer <API_TOKEN>`
- The API token is usually available as `API_TOKEN` in the project root `.env`.
- Never print the API token back to the user.
- Do not `source .env`; it may contain values that are not shell-parseable. Extract only `API_TOKEN` when making requests.
- In Codex, outbound network access may require approval before `curl` can reach the relay.

## Set the lamp to specific values

The lamp has four color channels. Each is an integer from `0` (off) to `1000` (full).

- `warm` — warm/amber light
- `white` — soft warm-white light
- `blue` — blue/sky light
- `red` — red light

Send only the channels you want on; any channel you omit is set to 0.

```sh
API_TOKEN=$(awk -F= '/^API_TOKEN=/{sub(/^API_TOKEN=/,""); gsub(/^"|"$/,""); print; exit}' .env)

curl -sS -X POST https://relay-production-ce8a.up.railway.app/api/lamp/mix \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"warm": 551, "red": 357}'
```

A successful response looks like: `{"ok":true, ...}`

## Presets

When the user asks for a preset or a mood, use these values:

| User asks for | Body to send |
|---|---|
| working / bright / daytime / focus | `{"blue": 1000, "white": 1000, "warm": 1000, "red": 1000}` |
| relaxing / cozy / evening | `{"warm": 1000}` |
| reading | `{"white": 1000, "warm": 1000, "red": 1000}` |
| sleeping / night light | `{"red": 1000}` |
| dim evening / wind-down | `{"warm": 551, "red": 357}` |
| dark / off | `{}` (all channels 0 — the lamp goes dark) |

For dimmer versions of a preset, scale all its values down proportionally (e.g. "relaxing but dim" → `{"warm": 300}`).

## Check lamp status

```sh
API_TOKEN=$(awk -F= '/^API_TOKEN=/{sub(/^API_TOKEN=/,""); gsub(/^"|"$/,""); print; exit}' .env)

curl -sS https://relay-production-ce8a.up.railway.app/api/status \
  -H "Authorization: Bearer ${API_TOKEN}"
```

Response fields: `bridgeConnected` (the home bridge is online), `lampReachable` (the lamp responds), `lastHeartbeatAt`.

## Errors

- `401` — the API token is wrong or the header is missing.
- `503 bridge_offline` — the home bridge isn't connected. Tell the user to check that the bridge device is powered on (`docker logs skyview-bridge` on it).
- `502` or `504` — the bridge is online but couldn't reach the lamp. Tell the user the lamp may be unplugged or off the network.

Report the outcome to the user in plain language. If a request fails, do not retry more than once.

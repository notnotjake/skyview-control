# skyview-control

This project controls a SkyView Pro / SkyView Light lamp without relying on the vendor app for daily use.

The intended architecture has three parts:

- `bridge`: a small service that runs on a local network device such as the Radxa ZERO 3W. It talks to the lamp over the Tuya local LAN protocol.
- `relay`: a Railway-hosted service that can receive commands from the app and forward them to the bridge over an outbound connection from the home network.
- `app`: the user-facing phone or web app for choosing presets, color mixes, fades, and schedules.

## Current State

The repo currently contains the reverse-engineering scratch tools under `work/`:

- `work/tuya-docker`: Dockerized TinyTuya wrappers and helper scripts.
- `work/tuya-data`: local device data, captures, protocol samples, and `.env`.

The `.env` file contains Tuya credentials and device secrets. Do not print it in logs and do not commit it to GitHub.

The old local virtualenv from the initial experiment was intentionally not moved into this project; Docker is the preferred isolation boundary.

## Known Device Details

- Device: SkyView Light / Sky View Pro lamp.
- Network protocol: Tuya local protocol `3.4`.
- Local LAN control works with TinyTuya when using the device IP, device ID, and local key.
- Tuya Cloud can read status and public functions, but it rejected the hidden DPS 51 payloads that provide full custom light-channel control.
- Practical conclusion: full control requires a local bridge on the same LAN as the lamp, or a VPN/tunnel into that LAN.

## DPS 51 Protocol Notes

The useful control surface is DPS `51`. It is a base64-encoded 12-byte binary payload:

- Byte 0: mode/command byte. Static custom mixes have worked with `2`.
- Byte 1: preset id. Preset `31` has been a good general-purpose base for custom mixes.
- Bytes 2-11: five big-endian `u16` fields.

The field mapping observed so far:

- Field 1: no obvious visible effect.
- Field 2: blue/top LED channel.
- Field 3: warm-white low LED channel.
- Field 4: warm/amber/pink low LED channel.
- Field 5: red LED channel.

Values are integers from `0` to `1000`.

Useful command shape from the project root:

```sh
work/tuya-docker/set-dps51 2 31 0 BLUE WHITE WARM RED 192.168.100.191
```

Known presets:

- `working`: `mode=2 preset=31 fields=[1000,1000,1000,1000,1000]`
- `relaxing`: `mode=2 preset=8 fields=[0,0,0,1000,0]`
- `reading`: `mode=2 preset=28 fields=[0,0,1000,1000,1000]`
- `sleeping`: `mode=2 preset=16 fields=[0,0,0,0,1000]`

## Working Commands

From the project root:

```sh
work/tuya-docker/status 192.168.100.191
work/tuya-docker/preset relaxing 192.168.100.191
work/tuya-docker/preset working 192.168.100.191
work/tuya-docker/set-dps51 2 31 0 0 0 551 357 192.168.100.191
```

The last example sends a custom warm/red dimmed mix.

## Product Direction

Build the real system in stages:

1. Turn the proven DPS 51 encoder and TinyTuya command path into a small bridge service.
2. Run the bridge on the Radxa ZERO 3W on the same Wi-Fi network as the lamp.
3. Add a Railway relay so the app can control the lamp remotely without opening inbound ports on the home network.
4. Build the app UI around friendly concepts: presets, channel mixer, brightness scaling, fades, schedules, and natural-light scenes.

Prefer keeping local hardware dependencies isolated and reproducible. Docker is acceptable on the bridge if memory stays comfortable; a small native Go or lean Python service is also viable.

# SkyView Tuya Docker Lab

This container keeps TinyTuya isolated from the Mac's Python environment.
It writes Tuya state files only into `work/tuya-data`, which is mounted as
`/data` inside the container.

## Build

```sh
docker build -t skyview-tuya work/tuya-docker
```

If your active Docker context is not running, use the known-working default
context:

```sh
docker --context default build -t skyview-tuya work/tuya-docker
```

## Run TinyTuya commands

```sh
docker run --rm -it \
  -v "$PWD/work/tuya-data:/data" \
  skyview-tuya scan
```

```sh
docker run --rm -it \
  -v "$PWD/work/tuya-data:/data" \
  skyview-tuya wizard
```

Or use the wrapper, which defaults to Docker's `default` context:

```sh
work/tuya-docker/run scan
work/tuya-docker/run wizard
```

For exploratory work, open an interactive shell inside the isolated container:

```sh
work/tuya-docker/shell
```

## Wizard From `.env`

Put Tuya credentials in `work/tuya-data/.env`:

```sh
TUYA_ACCESS_ID="..."
TUYA_ACCESS_SECRET="..."
TUYA_REGION="us"
TUYA_DEVICE_ID="..."
TUYA_DEVICE_IP="192.168.100.191"
TUYA_VERSION="3.4"
```

Then run:

```sh
work/tuya-docker/wizard-from-env
```

This passes `.env` into the container with `--env-file`, runs the TinyTuya
wizard, and writes `devices.json`, `tuya-raw.json`, `tinytuya.json`, and
possibly `snapshot.json` into `work/tuya-data`.

## Known Lamp Details

```text
Old eero IP: 192.168.4.21
Current IP:  192.168.100.191
Device ID:   eb14adaf5931de0d4b9ofl
Product ID:  ezcnuk6x27vuchov
Protocol:    3.4
Port:        6668
```

## Local Status And Control

Read status, using `TUYA_DEVICE_IP` from `.env`:

```sh
work/tuya-docker/status
```

Read status with an IP override:

```sh
work/tuya-docker/status 192.168.100.191
```

Set a DPS value:

```sh
work/tuya-docker/set-dps 20 true 192.168.100.191
work/tuya-docker/set-dps 22 500 192.168.100.191
```

Note: `22` is `bright_value`, but the lamp may ignore it visually while
`work_mode` (`21`) is `colour`; color-mode brightness appears to be encoded in
`colour_data` (`24`).

Set known app presets:

```sh
work/tuya-docker/preset working 192.168.100.191
work/tuya-docker/preset relaxing 192.168.100.191
work/tuya-docker/preset reading 192.168.100.191
work/tuya-docker/preset sleeping 192.168.100.191
```

Send custom DPS `51` values:

```sh
work/tuya-docker/set-dps51 MODE PRESET F1 F2 F3 F4 F5 192.168.100.191
work/tuya-docker/set-dps51 2 16 0 0 0 0 1000 192.168.100.191
work/tuya-docker/set-dps51 0 16 0 0 0 0 460 192.168.100.191
```

Capture app-driven states for mapping:

```sh
work/tuya-docker/capture red-night 192.168.100.191
work/tuya-docker/capture desired-app-state 192.168.100.191
work/tuya-docker/diff-captures work/tuya-data/captures/BEFORE.json work/tuya-data/captures/AFTER.json
```

Known DPS mapping:

```text
20 switch_led
21 work_mode: white, colour, scene, music
22 bright_value: 10-1000
23 temp_value: 0-1000
24 colour_data
25 scene_data
26 countdown
34 do_not_disturb
53 switch_night_light
27 music_data
28 control_data
51 hidden SkyView preset payload
```

Observed DPS `51` preset payloads:

```text
working    Ah8D6APoA+gD6APo  hex 021f03e803e803e803e803e8
relaxing   AggAAAAAAAAD6AAA  hex 020800000000000003e80000
reading    AhwAAAAAA+gD6APo  hex 021c0000000003e803e803e8
sleeping   AhAAAAAAAAAAAAPo  hex 0210000000000000000003e8
sleep 46%  ABAAAAAAAAAAAAHM  hex 0010000000000000000001cc
```

Confirmed by setting both presets locally.

DPS `51` appears to be a 12-byte payload:

```text
byte 0: command/group, observed 2 for preset selection and 0 for brightness adjustment
byte 1: preset id, observed 31 working, 28 reading, 16 sleeping, 8 relaxing
bytes 2-11: five big-endian 16-bit fields, often using Tuya's 0-1000 scale
```

Decode or encode candidates:

```sh
work/tuya-docker/dps51 decode Ah8D6APoA+gD6APo
work/tuya-docker/dps51 encode 2 31 1000 1000 1000 1000 1000
```

## DPS 51 Sampling Workflow

Monitor only the hidden DPS `51` preset payloads:

```sh
work/tuya-docker/monitor-dps51 192.168.100.191
```

While it is running, change one app control at a time. The monitor prints
compact events like:

```text
DPS51 event 1: preset=31 fields=[1000, 1000, 1000, 1000, 1000] payload=Ah8D6APoA+gD6APo
```

Make a note of what each event means, or record labeled samples:

```sh
work/tuya-docker/record-dps51 working Ah8D6APoA+gD6APo "bright daytime preset"
work/tuya-docker/record-dps51 relaxing AggAAAAAAAAD6AAA "warm glow preset"
```

Event logs are written to `work/tuya-data/dps51-events.jsonl`; labeled samples
are written to `work/tuya-data/dps51-samples.jsonl`.

## Tuya Cloud Tests

Use these to test whether the same device can be controlled through Tuya Cloud
without being on the lamp's LAN:

```sh
work/tuya-docker/cloud status
work/tuya-docker/cloud functions
```

Try a generic cloud command:

```sh
work/tuya-docker/cloud send switch_led true
```

Try sending hidden DPS `51` through cloud. This may or may not work depending on
whether Tuya Cloud exposes hidden DP `51`:

```sh
work/tuya-docker/cloud set-dps51 2 31 0 200 0 0 410
```

If `code: "51"` is rejected, inspect `cloud functions` for the exposed function
codes and try the relevant code if one maps to hidden control.

Observed result: Tuya Cloud rejected `code: "51"` with `command or value not
support`. Standard Tuya Cloud exposes the public function list only
(`switch_led`, `work_mode`, `bright_value`, `temp_value`, `colour_data`,
`scene_data`, `music_data`, `control_data`, `do_not_disturb`,
`switch_night_light`) and does not directly expose hidden DPS `51`.

## Docker/OrbStack Network Notes

On macOS, Docker Desktop runs containers behind a VM/NAT layer. Direct TCP
connections to the lamp's `:6668` port should usually work, but UDP broadcast
discovery may not behave the same as running TinyTuya directly on the Mac.

In the current OrbStack-backed Docker setup, direct TCP from the container to
the lamp's `:6668` port works after granting OrbStack macOS network permission.
That means local polling/control should be possible from the container once the
Tuya local key is known.

TinyTuya `scan` still does not discover the lamp from inside the container,
because UDP broadcast discovery stays on Docker's virtual network. Use the
known lamp details above rather than relying on containerized discovery.

If the lamp gets a new IP after re-pairing, scan the eero subnet for Tuya's
local TCP port:

```sh
docker --context default run --rm \
  -v "$PWD/work/tuya-docker:/tools:ro" \
  --entrypoint python \
  skyview-tuya /tools/scan_tuya_port.py 192.168.4.0/22 6668
```

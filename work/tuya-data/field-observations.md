# SkyView DPS 51 Field Observations

## Working Preset 31

Baseline:

```text
mode=2 preset=31 fields=[1000,1000,1000,1000,1000]
```

- Field 1: `1000 -> 500 -> 0` caused no obvious visual change.
- Field 1 only: `[1000,0,0,0,0]` and `[500,0,0,0,0]` both appeared visually
  off, same as `[0,0,0,0,0]`.
- Field 2: `1000 -> 0` made the lamp look less blue and more yellow.
- Field 2 only: `[0,1000,0,0,0]` made the lamp just blue.
- Preset 8 with field 2 only also showed the blue LED at 100%, so field 2
  appears stable across at least presets 8 and 31.
- Field 3: `1000 -> 0` made the lamp very blue/pink and not quite as bright;
  likely removes a bright/daylight or warm/white contribution.
- Field 3 only: `[0,0,1000,0,0]` produced warm white low on the lamp.
- Preset 8 with field 3 only produced the same warm white low result, so field
  3 appears stable across at least presets 8 and 31.
- Field 4: `1000 -> 0` seemed to remove the pink contribution.
- Field 4 only: `[0,0,0,1000,0]` produced a low warm color.
- Preset 8 with field 4 only produced the same low warm color, matching the
  known relaxing payload.
- Field 5: `1000 -> 0` caused little/no obvious visual change.
- Field 5 only: `[0,0,0,0,1000]` produced red.

## Byte 0 / Command Group

- Byte `2`, preset `16`, `[0,0,0,0,1000]` produced the known red state.
- Byte `0`, preset `16`, `[0,0,0,0,1000]` looked the same as byte `2`.
- Byte `0`, preset `16`, `[0,0,0,0,500]` dimmed the red channel to about half.
- Byte `1`, preset `16`, `[0,0,0,0,1000]` produced red at full brightness.
- Byte `3`, preset `16`, `[0,0,0,0,1000]` also produced red at full brightness.

## Saved Custom Presets

- `daytime-break`: warm and not too bright for daytime breaks.
  - User-facing channels: `blue=0`, `white=200`, `warm/amber=800`, `red=600`
  - DPS 51: `mode=2 preset=28 fields=[0,0,200,800,600]`
  - Payload: `AhwAAAAAAMgDIAJY`

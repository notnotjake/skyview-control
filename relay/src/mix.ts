import type { CommandPayload } from './hub'

const CHANNELS = ['blue', 'white', 'warm', 'red'] as const
type Channel = (typeof CHANNELS)[number]

export type MixResult =
  | { ok: true; payload: CommandPayload }
  | { ok: false; error: string }

/**
 * Validate a lamp/mix request body and build the DPS 51 command payload.
 * Channels are 0–1000 integers, missing defaults to 0. Anything else → error.
 */
export function buildMixPayload(body: unknown): MixResult {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'body must be a JSON object' }
  }
  const obj = body as Record<string, unknown>

  for (const key of Object.keys(obj)) {
    if (!(CHANNELS as readonly string[]).includes(key)) {
      return { ok: false, error: `unknown field: ${key}` }
    }
  }

  const values: Record<Channel, number> = { blue: 0, white: 0, warm: 0, red: 0 }
  for (const ch of CHANNELS) {
    const v = obj[ch]
    if (v === undefined) continue
    if (typeof v !== 'number' || !Number.isInteger(v)) {
      return { ok: false, error: `${ch} must be an integer` }
    }
    if (v < 0 || v > 1000) {
      return { ok: false, error: `${ch} must be between 0 and 1000` }
    }
    values[ch] = v
  }

  // fields = [f1=0, blue, white, warm, red]
  return {
    ok: true,
    payload: {
      mode: 2,
      preset: 31,
      fields: [0, values.blue, values.white, values.warm, values.red],
    },
  }
}

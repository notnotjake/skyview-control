import { Hono } from 'hono'
import { createBunWebSocket } from 'hono/bun'
import { isAuthorized } from './auth'
import { Hub, log, type Socket } from './hub'
import { buildMixPayload } from './mix'

// --- Config -----------------------------------------------------------------

const API_TOKEN = process.env.API_TOKEN ?? ''
const BRIDGE_TOKEN = process.env.BRIDGE_TOKEN ?? ''
const PORT = Number(process.env.PORT ?? 3000)

if (!API_TOKEN) {
  console.error('FATAL: API_TOKEN env is required')
  process.exit(1)
}
if (!BRIDGE_TOKEN) {
  console.error('FATAL: BRIDGE_TOKEN env is required')
  process.exit(1)
}

// --- Wiring -----------------------------------------------------------------

const hub = new Hub()
const { upgradeWebSocket, websocket } = createBunWebSocket()
const app = new Hono()

// Path to the repo-root install.sh (relay is started from repo root per
// railway.json; resolve relative to this file so local runs work too).
const installShPath = new URL('../../install.sh', import.meta.url).pathname

// --- Public endpoints -------------------------------------------------------

app.get('/healthz', (c) => c.json({ ok: true }))

app.get('/install.sh', async (c) => {
  const file = Bun.file(installShPath)
  if (!(await file.exists())) {
    return c.text('install.sh not found', 404)
  }
  return new Response(file, {
    headers: { 'Content-Type': 'text/x-shellscript' },
  })
})

// --- Authenticated API ------------------------------------------------------

app.use('/api/*', async (c, next) => {
  if (!isAuthorized(c.req.header('Authorization'), API_TOKEN)) {
    return c.json({ error: 'unauthorized' }, 401)
  }
  await next()
})

app.get('/api/status', (c) => c.json(hub.status()))

app.post('/api/lamp/mix', async (c) => {
  let body: unknown
  try {
    body = await c.req.json()
  } catch {
    return c.json({ error: 'invalid JSON body' }, 400)
  }

  const built = buildMixPayload(body)
  if (!built.ok) {
    return c.json({ error: built.error }, 400)
  }

  const pending = hub.sendCommand(built.payload)
  if (pending === null) {
    return c.json({ error: 'bridge_offline' }, 503)
  }

  const result = await pending
  if (result.error === 'bridge_timeout') {
    return c.json({ error: 'bridge_timeout' }, 504)
  }
  if (result.error === 'bridge_offline') {
    return c.json({ error: 'bridge_offline' }, 503)
  }
  if (!result.ok) {
    return c.json({ error: result.error ?? 'bridge_error' }, 502)
  }
  return c.json({ ok: true, id: result.id, lampReachable: result.lampReachable })
})

// --- Bridge WebSocket -------------------------------------------------------

app.get('/bridge', (c) => {
  // Auth happens here, at upgrade time, from the upgrade request headers.
  if (!isAuthorized(c.req.header('Authorization'), BRIDGE_TOKEN)) {
    return c.text('unauthorized', 401)
  }

  const handler = upgradeWebSocket(() => {
    // Adapt Hono's ws wrapper to the minimal Socket interface the hub uses.
    let sock: Socket
    return {
      onOpen(_evt, ws) {
        sock = {
          send: (data: string) => ws.send(data),
          close: (code?: number, reason?: string) => ws.close(code, reason),
        }
      },
      onMessage(evt, ws) {
        if (!sock) {
          sock = {
            send: (data: string) => ws.send(data),
            close: (code?: number, reason?: string) => ws.close(code, reason),
          }
        }
        handleBridgeMessage(sock, evt.data)
      },
      onClose() {
        if (sock) hub.handleClose(sock)
      },
    }
  })

  return handler(c, async () => {})
})

function handleBridgeMessage(sock: Socket, raw: unknown): void {
  if (typeof raw !== 'string') return
  let msg: any
  try {
    msg = JSON.parse(raw)
  } catch {
    log('bridge sent non-JSON frame; ignored')
    return
  }

  switch (msg?.type) {
    case 'hello':
      hub.registerHello(sock, {
        bridgeId: msg.bridgeId,
        version: msg.version,
        lampIp: msg.lampIp,
        lampReachable: msg.lampReachable,
      })
      break
    case 'heartbeat':
      hub.registerHeartbeat({
        lampReachable: msg.lampReachable,
        lampIp: msg.lampIp,
        ts: msg.ts,
      })
      break
    case 'result':
      hub.resolveResult({
        ok: !!msg.ok,
        id: String(msg.id),
        error: msg.error ?? null,
        lampReachable: msg.lampReachable ?? null,
      })
      break
    default:
      log(`bridge sent unknown message type: ${msg?.type}`)
  }
}

// --- Serve ------------------------------------------------------------------

const server = Bun.serve({
  port: PORT,
  fetch: app.fetch,
  websocket,
})

log(`relay listening on :${server.port}`)

function shutdown(): void {
  log('shutting down')
  server.stop(true)
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)

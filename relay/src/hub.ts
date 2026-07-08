// Bridge socket registry + pending-command correlation.
//
// A single bridge connection is canonical at any time (last hello wins). The
// hub tracks connection/heartbeat liveness and correlates command ids with
// their results, timing out after 15s.

const COMMAND_TIMEOUT_MS = 15_000
const HEARTBEAT_STALE_MS = 60_000

export interface CommandPayload {
  mode: number
  preset: number
  fields: [number, number, number, number, number]
}

export interface CommandResult {
  ok: boolean
  id: string
  error: string | null
  lampReachable: boolean | null
}

export interface StatusView {
  bridgeConnected: boolean
  bridgeVersion: string | null
  lastHeartbeatAt: string | null
  lampReachable: boolean | null
  lampIp: string | null
}

// Minimal shape we need from a WS server socket (works for Bun's ServerWebSocket
// as surfaced by Hono's createBunWebSocket context).
export interface Socket {
  send(data: string): void
  close(code?: number, reason?: string): void
}

interface Pending {
  resolve: (r: CommandResult) => void
  timer: ReturnType<typeof setTimeout>
}

export class Hub {
  private socket: Socket | null = null
  private bridgeVersion: string | null = null
  private lampReachable: boolean | null = null
  private lampIp: string | null = null
  private lastSeenAt: number | null = null // ms epoch of last hello/heartbeat
  private lastHeartbeatAt: string | null = null // iso reported by bridge
  private pending = new Map<string, Pending>()

  /** Register a freshly-arrived hello. Closes any previous socket. */
  registerHello(
    socket: Socket,
    info: { bridgeId?: string; version?: string; lampIp?: string; lampReachable?: boolean },
  ): void {
    const previous = this.socket
    // Adopt the new socket first so that closing the previous one (which may
    // fire its onClose synchronously) sees a different canonical socket and
    // no-ops in handleClose rather than tearing down the new connection.
    this.socket = socket
    if (previous && previous !== socket) {
      log('bridge replaced (new hello); closing old socket')
      try {
        previous.close(1000, 'replaced')
      } catch {
        // old socket may already be gone
      }
    }
    this.bridgeVersion = info.version ?? null
    this.lampIp = info.lampIp ?? null
    this.lampReachable = info.lampReachable ?? null
    this.lastSeenAt = Date.now()
    this.lastHeartbeatAt = new Date().toISOString()
    log(`bridge hello: ${info.bridgeId ?? 'unknown'} v${info.version ?? '?'} lamp=${info.lampIp ?? '?'} reachable=${info.lampReachable}`)
  }

  registerHeartbeat(info: { lampReachable?: boolean; lampIp?: string; ts?: string }): void {
    this.lastSeenAt = Date.now()
    if (info.lampReachable !== undefined) this.lampReachable = info.lampReachable
    if (info.lampIp !== undefined) this.lampIp = info.lampIp
    this.lastHeartbeatAt = info.ts ?? new Date().toISOString()
  }

  /** Resolve a pending command from a bridge result. */
  resolveResult(result: CommandResult): void {
    const p = this.pending.get(result.id)
    if (!p) return
    clearTimeout(p.timer)
    this.pending.delete(result.id)
    p.resolve(result)
  }

  /**
   * Called when a bridge socket closes. If it is the canonical socket, drop it
   * and reject every pending command with bridge_offline.
   */
  handleClose(socket: Socket): void {
    if (this.socket !== socket) return // a superseded zombie; nothing tracked
    this.socket = null
    this.bridgeVersion = null
    this.lampReachable = null
    this.lastSeenAt = null
    log('bridge disconnected')
    this.rejectAllPending('bridge_offline')
  }

  private rejectAllPending(error: string): void {
    for (const [id, p] of this.pending) {
      clearTimeout(p.timer)
      p.resolve({ ok: false, id, error, lampReachable: null })
    }
    this.pending.clear()
  }

  /** True if a socket is present and a heartbeat/hello was seen within 60s. */
  isConnected(): boolean {
    if (!this.socket || this.lastSeenAt === null) return false
    return Date.now() - this.lastSeenAt <= HEARTBEAT_STALE_MS
  }

  status(): StatusView {
    const connected = this.isConnected()
    return {
      bridgeConnected: connected,
      bridgeVersion: connected ? this.bridgeVersion : null,
      lastHeartbeatAt: this.lastHeartbeatAt,
      lampReachable: connected ? this.lampReachable : null,
      lampIp: this.lampIp,
    }
  }

  /**
   * Send a command to the bridge and await its result (or timeout).
   * Returns null if no bridge is connected.
   */
  sendCommand(payload: CommandPayload): Promise<CommandResult> | null {
    if (!this.isConnected() || !this.socket) return null
    const id = crypto.randomUUID()
    const message = JSON.stringify({ type: 'command', id, action: 'dps51', payload })

    return new Promise<CommandResult>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        resolve({ ok: false, id, error: 'bridge_timeout', lampReachable: null })
      }, COMMAND_TIMEOUT_MS)
      this.pending.set(id, { resolve, timer })
      try {
        this.socket!.send(message)
      } catch (err) {
        clearTimeout(timer)
        this.pending.delete(id)
        resolve({ ok: false, id, error: 'bridge_offline', lampReachable: null })
      }
    })
  }
}

export function log(msg: string): void {
  console.log(`${new Date().toISOString()} ${msg}`)
}

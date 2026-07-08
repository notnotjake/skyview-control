import { timingSafeEqual, createHash } from 'node:crypto'

// Constant-time comparison of a candidate bearer value against the expected
// token. Both sides are hashed to a fixed length so timingSafeEqual never sees
// differing-length buffers (which would itself leak length and throw).
function tokensMatch(candidate: string, expected: string): boolean {
  const a = createHash('sha256').update(candidate).digest()
  const b = createHash('sha256').update(expected).digest()
  return timingSafeEqual(a, b)
}

/** Extract a Bearer token from an Authorization header value. */
function bearer(header: string | undefined | null): string | null {
  if (!header) return null
  const m = header.match(/^Bearer (.+)$/)
  return m ? m[1] : null
}

/** True if the Authorization header carries a Bearer token matching `expected`. */
export function isAuthorized(header: string | undefined | null, expected: string): boolean {
  const token = bearer(header)
  if (token === null) return false
  return tokensMatch(token, expected)
}

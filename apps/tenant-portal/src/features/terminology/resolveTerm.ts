import {
  foldTermValue,
  isTermKey,
  TERM_DENIED_FOLDED,
  TERM_KEYS,
  TERM_MAX_LEN,
  TERM_MIN_LEN,
  type TermKey,
} from './termCatalog'

const TERM_VALUE_RE = /^[\p{L}\p{N} '\-·?¿!]+$/u

export function readStringMap(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  return value as Record<string, unknown>
}

function rawString(map: Record<string, unknown>, key: string): string | null {
  const value = map[key]
  return typeof value === 'string' ? value : null
}

/** Trim, collapse spaces, charset, length, denylist. Null = reject / omit. */
export function sanitizeTermValue(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  if (/[<>]/.test(raw) || /https?:\/\//i.test(raw)) return null
  const cleaned = raw.trim().replace(/\s+/g, ' ')
  if (cleaned.length < TERM_MIN_LEN || cleaned.length > TERM_MAX_LEN) return null
  if (!TERM_VALUE_RE.test(cleaned)) return null
  if (TERM_DENIED_FOLDED.has(foldTermValue(cleaned))) return null
  return cleaned
}

export function sanitizeTerminologyMap(value: unknown): Partial<Record<TermKey, string>> {
  const map = readStringMap(value)
  const out: Partial<Record<TermKey, string>> = {}
  for (const key of TERM_KEYS) {
    const cleaned = sanitizeTermValue(rawString(map, key))
    if (cleaned) out[key] = cleaned
  }
  return out
}

export type TermOrigin = 'tenant' | 'sector' | 'platform'

export function resolveTerm(
  key: string,
  sources: {
    tenant?: unknown
    sector?: unknown
    fallback: string
  },
): string {
  if (isTermKey(key)) {
    const overlay = sanitizeTermValue(rawString(readStringMap(sources.tenant), key))
    if (overlay) return overlay
  }
  const sector = rawString(readStringMap(sources.sector), key)?.trim()
  if (sector) return sector
  return sources.fallback
}

/** Where the effective name comes from (saved overlay, not draft). */
export function termOrigin(
  key: string,
  sources: { tenant?: unknown; sector?: unknown },
): TermOrigin {
  if (isTermKey(key)) {
    const overlay = sanitizeTermValue(rawString(readStringMap(sources.tenant), key))
    if (overlay) return 'tenant'
  }
  const sector = rawString(readStringMap(sources.sector), key)?.trim()
  if (sector) return 'sector'
  return 'platform'
}

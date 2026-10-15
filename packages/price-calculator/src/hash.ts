import type { OutputLine } from './types.ts'

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (value !== null && typeof value === 'object') {
    const obj = value as Record<string, unknown>
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(obj).sort()) {
      out[key] = sortKeys(obj[key])
    }
    return out
  }
  return value
}

/** JSON canònic: claus ordenades, sense espais. */
export function canonicalLinesJson(lines: OutputLine[]): string {
  return JSON.stringify(sortKeys(lines))
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/** SHA-256 hex del JSON canònic de les línies (D14). */
export async function hashLines(lines: OutputLine[]): Promise<string> {
  const json = canonicalLinesJson(lines)
  const data = new TextEncoder().encode(json)
  const digest = await crypto.subtle.digest('SHA-256', data)
  return toHex(digest)
}

/**
 * Safe in-app return navigation via `?returnTo=` (whitelist of relative paths).
 * Prefer query over history.back so refresh / new-tab / shared links keep context.
 */

const RETURN_TO_PARAM = 'returnTo'

const ALLOWED_PREFIXES = [
  '/quotes',
  '/field/orders',
  '/field/today',
  '/field/agenda',
  '/projects',
  '/contacts/',
  '/documents',
  '/agreements',
] as const

export function isAllowedReturnTo(path: string | null | undefined): path is string {
  if (!path || typeof path !== 'string') return false
  if (!path.startsWith('/') || path.startsWith('//')) return false
  if (path.includes('://') || path.includes('\\')) return false
  try {
    const url = new URL(path, 'http://local.invalid')
    if (url.origin !== 'http://local.invalid') return false
    const pathname = url.pathname
    return ALLOWED_PREFIXES.some(
      (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`) || pathname.startsWith(prefix),
    )
  } catch {
    return false
  }
}

/** Encode a relative path (+ optional search) for use as `returnTo` query value. */
export function encodeReturnTo(pathWithSearch: string): string {
  return encodeURIComponent(pathWithSearch)
}

/** Read and validate `returnTo` from URLSearchParams or a raw string. */
export function readReturnTo(
  searchParams: URLSearchParams | { get: (key: string) => string | null },
): string | null {
  const raw = searchParams.get(RETURN_TO_PARAM)
  if (!raw) return null
  let decoded = raw
  try {
    decoded = decodeURIComponent(raw)
  } catch {
    return null
  }
  return isAllowedReturnTo(decoded) ? decoded : null
}

/** Append `returnTo` to a path (preserves existing query). */
export function withReturnTo(to: string, returnTo: string | null | undefined): string {
  if (!returnTo || !isAllowedReturnTo(returnTo)) return to
  const url = new URL(to, 'http://local.invalid')
  url.searchParams.set(RETURN_TO_PARAM, returnTo)
  return `${url.pathname}${url.search}${url.hash}`
}

/**
 * Build a document DMS link that can return to the commercial quote/order view.
 */
export function documentPathWithReturn(documentId: string, returnTo: string | null | undefined): string {
  return withReturnTo(`/documents/${documentId}`, returnTo)
}

export { RETURN_TO_PARAM }

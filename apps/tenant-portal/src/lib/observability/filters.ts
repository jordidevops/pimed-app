/** Errors esperats (4xx negoci/auth) — no enviar a Sentry. */
export function isExpectedClientError(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false

  const record = error as Record<string, unknown>

  if (typeof record.status === 'number' && record.status >= 400 && record.status < 500) {
    return true
  }

  if (typeof record.statusCode === 'number' && record.statusCode >= 400 && record.statusCode < 500) {
    return true
  }

  const name = String(record.name ?? '')
  if (name === 'AuthApiError' || name === 'AuthError') return true

  const code = String(record.code ?? '')
  if (code.startsWith('PGRST') || code === '42501') return true

  const message = String(record.message ?? error ?? '')
  if (/rate_limit|permission denied|jwt expired|invalid login/i.test(message)) return true

  return false
}

export function shouldDropSentryEvent(environment: string, error: unknown, message?: string): boolean {
  if (environment === 'local') return true
  if (isExpectedClientError(error)) return true
  if (message && /rate_limit_exceeded/i.test(message)) return true
  return false
}

export function isRetryableSyncError(err: unknown): boolean {
  const value = (typeof err === 'object' && err !== null)
    ? err as { message?: unknown; code?: unknown; status?: unknown }
    : {}
  const message = String(
    value.message ?? (err instanceof Error ? err.message : err ?? ''),
  ).toLowerCase()
  const code = String(value.code ?? '').toUpperCase()
  const status = Number(value.status)

  if (Number.isFinite(status)) {
    if (status >= 500 || status === 408 || status === 429) return true
    if (status === 401 || status === 403) return false
  }

  if (
    code.startsWith('08') ||
    code.startsWith('53') ||
    code === '40001' ||
    code === '40P01' ||
    code === '55P03' ||
    code === '57014' ||
    code.startsWith('PGRST0')
  ) {
    return true
  }

  return [
    'network',
    'fetch',
    'timeout',
    'timed out',
    'connection',
    'service unavailable',
    'bad gateway',
    'gateway timeout',
    'temporarily unavailable',
  ].some((token) => message.includes(token))
}

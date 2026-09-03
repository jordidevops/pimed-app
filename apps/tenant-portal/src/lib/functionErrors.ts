export async function getFunctionErrorMessage(error: unknown): Promise<string | null> {
  if (typeof error !== 'object' || error === null || !('context' in error)) {
    return null
  }

  const context = (error as { context?: unknown }).context
  if (!(context instanceof Response)) {
    return null
  }

  try {
    const payload = (await context.clone().json()) as {
      message?: unknown
      error?: unknown
    }
    if (typeof payload.message === 'string' && payload.message.trim()) {
      return payload.message
    }
    if (typeof payload.error === 'string' && payload.error.trim()) {
      return payload.error
    }
    if (
      typeof payload.error === 'object' &&
      payload.error !== null &&
      'message' in payload.error &&
      typeof (payload.error as { message?: unknown }).message === 'string'
    ) {
      const nested = (payload.error as { message: string }).message.trim()
      if (nested) return nested
    }
  } catch {
    try {
      const text = await context.clone().text()
      if (text.trim()) return text
    } catch {
      return null
    }
  }

  return null
}

export function getResponseErrorMessage(data: unknown): string | null {
  if (typeof data !== 'object' || data === null) return null
  const payload = data as { error?: unknown; message?: unknown }
  if (typeof payload.error === 'string' && payload.error.trim()) return payload.error
  if (
    typeof payload.error === 'object' &&
    payload.error !== null &&
    'message' in payload.error &&
    typeof (payload.error as { message?: unknown }).message === 'string'
  ) {
    const nested = (payload.error as { message: string }).message.trim()
    if (nested) return nested
  }
  if (typeof payload.message === 'string' && payload.message.trim()) return payload.message
  return null
}

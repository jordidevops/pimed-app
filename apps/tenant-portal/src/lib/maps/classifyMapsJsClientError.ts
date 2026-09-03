/**
 * Classify Google Maps JS loader / auth failures for telemetry.
 * Prefer official error names when present in the message payload.
 * @see https://developers.google.com/maps/documentation/javascript/error-messages
 */

export type MapsJsClientErrorClass = {
  category: 'auth_failure' | 'quota' | 'config' | 'network' | 'maps_js'
  code: string
}

const KNOWN: Array<{ match: RegExp; category: MapsJsClientErrorClass['category']; code: string }> = [
  { match: /\bgm_authfailure\b|auth_failure/i, category: 'auth_failure', code: 'gm_authFailure' },
  { match: /InvalidKeyMapError/i, category: 'auth_failure', code: 'InvalidKeyMapError' },
  { match: /ExpiredKeyMapError/i, category: 'auth_failure', code: 'ExpiredKeyMapError' },
  { match: /RefererNotAllowedMapError/i, category: 'auth_failure', code: 'RefererNotAllowedMapError' },
  { match: /ApiNotActivatedMapError/i, category: 'config', code: 'ApiNotActivatedMapError' },
  { match: /BillingNotEnabledMapError/i, category: 'config', code: 'BillingNotEnabledMapError' },
  { match: /DeletedApiProjectMapError/i, category: 'config', code: 'DeletedApiProjectMapError' },
  { match: /ProjectDeniedMapError/i, category: 'auth_failure', code: 'ProjectDeniedMapError' },
  { match: /ClientServerBlockedMapError/i, category: 'auth_failure', code: 'ClientServerBlockedMapError' },
  { match: /OverQuotaMapError/i, category: 'quota', code: 'OverQuotaMapError' },
  { match: /RequestDeniedMapError/i, category: 'auth_failure', code: 'RequestDeniedMapError' },
  { match: /InvalidAppCheckTokenMapError/i, category: 'auth_failure', code: 'InvalidAppCheckTokenMapError' },
  { match: /MapError/i, category: 'maps_js', code: 'MapError' },
  { match: /Failed to load|LoadingError|network|fetch failed|ERR_NETWORK/i, category: 'network', code: 'load_failed' },
  { match: /AUTH_FAILURE/i, category: 'auth_failure', code: 'AUTH_FAILURE' },
]

function errorToText(error: unknown): string {
  if (error == null) return ''
  if (typeof error === 'string') return error
  if (error instanceof Error) {
    return [error.name, error.message, error.stack].filter(Boolean).join(' ')
  }
  if (typeof error === 'object') {
    try {
      return JSON.stringify(error)
    } catch {
      return String(error)
    }
  }
  return String(error)
}

export function classifyMapsJsClientError(error: unknown): MapsJsClientErrorClass {
  const text = errorToText(error)
  for (const rule of KNOWN) {
    if (rule.match.test(text)) {
      return { category: rule.category, code: rule.code }
    }
  }
  return { category: 'maps_js', code: 'unknown_error' }
}

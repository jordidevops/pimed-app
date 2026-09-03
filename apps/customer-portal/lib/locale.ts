export const PLATFORM_LOCALES = ['ca', 'es', 'en'] as const
export type PlatformLocale = (typeof PLATFORM_LOCALES)[number]

export const UI_LOCALE_COOKIE = 'cp_ui_locale'
export const PLATFORM_FALLBACK_LOCALE: PlatformLocale = 'es'

export function isPlatformLocale(value: string): value is PlatformLocale {
  return (PLATFORM_LOCALES as readonly string[]).includes(value)
}

export function normalizeSupportedLocales(
  locales: unknown,
): PlatformLocale[] {
  if (!Array.isArray(locales)) return [...PLATFORM_LOCALES]
  const out = locales.filter(
    (l): l is PlatformLocale => typeof l === 'string' && isPlatformLocale(l),
  )
  return out.length > 0 ? out : [...PLATFORM_LOCALES]
}

/**
 * preferred if in supported → defaultLocale → es.
 * cookieLocale is only an immediate overlay when allow_change was used;
 * prefer DB preferred so tenant/account updates win over a stale cookie.
 */
export function resolveUiLocale(params: {
  preferred?: string | null
  supported?: unknown
  defaultLocale?: string | null
  cookieLocale?: string | null
}): PlatformLocale {
  const supported = normalizeSupportedLocales(params.supported)
  const preferred = params.preferred?.trim().toLowerCase()
  if (preferred && isPlatformLocale(preferred) && supported.includes(preferred)) {
    return preferred
  }
  const cookie = params.cookieLocale?.trim().toLowerCase()
  if (cookie && isPlatformLocale(cookie) && supported.includes(cookie)) {
    return cookie
  }
  const fallback = params.defaultLocale?.trim().toLowerCase()
  if (fallback && isPlatformLocale(fallback) && supported.includes(fallback)) {
    return fallback
  }
  if (fallback && isPlatformLocale(fallback)) {
    return fallback
  }
  return PLATFORM_FALLBACK_LOCALE
}

export function localeFieldsFromResolve(result: {
  preferred_locale?: string | null
  supported_locales?: unknown
  default_locale?: string | null
  allow_client_locale_change?: boolean
}): {
  preferred: string | null
  supported: PlatformLocale[]
  defaultLocale: string
  allowClientLocaleChange: boolean
} {
  return {
    preferred: result.preferred_locale ?? null,
    supported: normalizeSupportedLocales(result.supported_locales),
    defaultLocale:
      typeof result.default_locale === 'string' && result.default_locale
        ? result.default_locale
        : PLATFORM_FALLBACK_LOCALE,
    allowClientLocaleChange: result.allow_client_locale_change === true,
  }
}

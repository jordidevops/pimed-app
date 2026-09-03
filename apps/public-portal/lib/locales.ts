export const VALID_LOCALES = ['ca', 'es', 'en'] as const
export type SupportedLocale = (typeof VALID_LOCALES)[number]

export const PLATFORM_FALLBACK_LOCALE: SupportedLocale = 'es'

export function isValidLocale(v: string): v is SupportedLocale {
  return VALID_LOCALES.includes(v as SupportedLocale)
}

export function normalizeSupportedLocales(locales: string[] | null | undefined): SupportedLocale[] {
  const normalized = (locales ?? []).filter((l): l is SupportedLocale => isValidLocale(l))
  return normalized.length > 0 ? normalized : [PLATFORM_FALLBACK_LOCALE]
}

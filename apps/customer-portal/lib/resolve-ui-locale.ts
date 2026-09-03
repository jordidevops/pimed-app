import type { ResolveOk } from '@/lib/constants'
import {
  localeFieldsFromResolve,
  resolveUiLocale,
  type PlatformLocale,
} from '@/lib/locale'

export function uiLocaleFromResolve(
  result: ResolveOk,
  cookieLocale?: string | null,
): {
  uiLocale: PlatformLocale
  supported: PlatformLocale[]
  allowClientLocaleChange: boolean
} {
  const fields = localeFieldsFromResolve(result)
  return {
    uiLocale: resolveUiLocale({
      preferred: fields.preferred,
      supported: fields.supported,
      defaultLocale: fields.defaultLocale,
      cookieLocale,
    }),
    supported: fields.supported,
    allowClientLocaleChange: fields.allowClientLocaleChange,
  }
}

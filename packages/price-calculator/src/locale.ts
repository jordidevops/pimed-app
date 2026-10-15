import type { LocaleMap } from './types.ts'

/** D8: idioma actiu → ca → primera clau no buida. */
export function resolveLocale(map: LocaleMap | undefined, locale = 'ca'): string {
  if (!map) return ''
  const primary = map[locale as keyof LocaleMap]
  if (primary && primary.trim()) return primary
  if (map.ca && map.ca.trim()) return map.ca
  for (const v of Object.values(map)) {
    if (typeof v === 'string' && v.trim()) return v
  }
  return ''
}

export function fillPlaceholders(
  template: string,
  params: Record<string, string>,
): string {
  return template.replace(/\{\{([a-z][a-z0-9_]{0,40})\}\}/g, (_, key: string) => {
    return params[key] ?? `{{${key}}}`
  })
}

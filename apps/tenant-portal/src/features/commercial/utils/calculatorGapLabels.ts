import type { Definition } from '@pimed/price-calculator'
import { resolveLocale, type ValidationIssue } from '@pimed/price-calculator'

/** Etiquetes llegibles per paths d'activationGaps. */
export function formatActivationGapList(
  definition: Definition,
  gaps: ValidationIssue[],
  locale = 'ca',
): string {
  return gaps.map((g) => formatActivationGap(definition, g, locale)).join(', ')
}

export function formatActivationGap(
  definition: Definition,
  gap: ValidationIssue,
  locale = 'ca',
): string {
  const assumed = gap.message === 'assumed' ? ' (assumit)' : ''
  const constMatch = /^constants\.(.+)$/.exec(gap.path)
  if (constMatch) {
    const key = constMatch[1]!
    const c = definition.constants?.find((x) => x.key === key)
    const label = c ? resolveLocale(c.label, locale) || key : key
    return `${label}${assumed}`
  }
  const tableMatch = /^tables\.([^.]+)\[(\d+)\](?:\.(.+))?$/.exec(gap.path)
  if (tableMatch) {
    const tableKey = tableMatch[1]!
    const rowIndex = Number(tableMatch[2])
    const field = tableMatch[3]
    const table = definition.tables?.find((t) => t.key === tableKey)
    const rowLabel = table?.rows[rowIndex]
      ? resolveLocale(
          typeof table.rows[rowIndex]!.label === 'object'
            ? (table.rows[rowIndex]!.label as never)
            : undefined,
          locale,
        ) || `tram ${rowIndex + 1}`
      : `tram ${rowIndex + 1}`
    if (!field) return `${tableKey} → ${rowLabel}${assumed}`
    return `${tableKey} → ${rowLabel} → ${field}${assumed}`
  }
  return `${gap.path}${assumed}`
}

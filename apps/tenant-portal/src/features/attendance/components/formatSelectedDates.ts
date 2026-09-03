import { formatIsoDateWithPattern } from '@/lib/formatDatePattern'

const MAX_VISIBLE_DATES = 4

/** True when every day between min and max is included (inclusive). */
export function isConsecutiveDateRange(sortedDates: string[]): boolean {
  if (sortedDates.length <= 1) return true
  for (let i = 1; i < sortedDates.length; i++) {
    const prev = new Date(`${sortedDates[i - 1]}T12:00:00`)
    const cur = new Date(`${sortedDates[i]}T12:00:00`)
    prev.setDate(prev.getDate() + 1)
    if (prev.toISOString().slice(0, 10) !== cur.toISOString().slice(0, 10)) return false
  }
  return true
}

type TFn = (key: string, defaultValue: string, options?: Record<string, unknown>) => string

/** Label for a multi-day selection: range if consecutive, comma-separated list otherwise. */
export function formatSelectedDatesLabel(
  sortedDates: string[],
  dateFormat: string,
  t: TFn,
): string {
  if (sortedDates.length === 0) return ''
  if (sortedDates.length === 1) {
    return formatIsoDateWithPattern(sortedDates[0], dateFormat)
  }

  if (isConsecutiveDateRange(sortedDates)) {
    return t('calendar.selected_range', '{{start}} → {{end}} ({{count}} dies)', {
      start: formatIsoDateWithPattern(sortedDates[0], dateFormat),
      end: formatIsoDateWithPattern(sortedDates[sortedDates.length - 1], dateFormat),
      count: sortedDates.length,
    })
  }

  const formatted = sortedDates.map((d) => formatIsoDateWithPattern(d, dateFormat))
  if (formatted.length <= MAX_VISIBLE_DATES) {
    return formatted.join(', ')
  }
  const visible = formatted.slice(0, MAX_VISIBLE_DATES).join(', ')
  return t('calendar.selected_list_overflow', '{{list}}, …', { list: visible })
}

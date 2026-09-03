/** Local calendar helpers — avoid UTC day-shift from toISOString().slice(0,10). */

export function localDateString(d = new Date()): string {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

/** Inclusive local-day range as ISO timestamptz bounds. */
export function localDayRange(day?: string): { from: string; to: string; day: string } {
  const base = day ?? localDateString()
  const [y, m, d] = base.split('-').map(Number)
  const start = new Date(y, m - 1, d, 0, 0, 0, 0)
  const end = new Date(y, m - 1, d, 23, 59, 59, 999)
  return { from: start.toISOString(), to: end.toISOString(), day: base }
}

/** Start of local day for `day` through end of local day `day + daysAhead`. */
export function localDaysAheadRange(daysAhead: number, fromDay?: string): { from: string; to: string; day: string } {
  const day = fromDay ?? localDateString()
  const [y, m, d] = day.split('-').map(Number)
  const start = new Date(y, m - 1, d, 0, 0, 0, 0)
  const end = new Date(y, m - 1, d + daysAhead, 23, 59, 59, 999)
  return { from: start.toISOString(), to: end.toISOString(), day }
}

/** Monday-based week (local calendar). */
function localMonday(d: Date): Date {
  const copy = new Date(d.getFullYear(), d.getMonth(), d.getDate())
  const day = copy.getDay()
  const diff = day === 0 ? -6 : 1 - day
  copy.setDate(copy.getDate() + diff)
  copy.setHours(0, 0, 0, 0)
  return copy
}

export type PlannedDateRangeKey = 'today' | 'this_week' | 'last_week' | 'month'

/** Date-only bounds for planned_start filters (YYYY-MM-DD). */
export function plannedDateRangeBounds(key: PlannedDateRangeKey): { from: string; to: string } {
  const now = new Date()
  if (key === 'today') {
    const day = localDateString(now)
    return { from: day, to: day }
  }
  if (key === 'this_week') {
    const start = localMonday(now)
    const end = new Date(start)
    end.setDate(end.getDate() + 6)
    return { from: localDateString(start), to: localDateString(end) }
  }
  if (key === 'last_week') {
    const thisMonday = localMonday(now)
    const start = new Date(thisMonday)
    start.setDate(start.getDate() - 7)
    const end = new Date(start)
    end.setDate(end.getDate() + 6)
    return { from: localDateString(start), to: localDateString(end) }
  }
  const start = new Date(now.getFullYear(), now.getMonth(), 1)
  const end = new Date(now.getFullYear(), now.getMonth() + 1, 0)
  return { from: localDateString(start), to: localDateString(end) }
}

export function formatElapsedSeconds(totalSeconds: number): string {
  const safe = Math.max(0, Math.floor(totalSeconds))
  const h = Math.floor(safe / 3600)
  const m = Math.floor((safe % 3600) / 60)
  const s = safe % 60
  if (h > 0) {
    return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  }
  return `${m}:${String(s).padStart(2, '0')}`
}

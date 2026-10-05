export function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

/** Inclusive end of the local calendar day (23:59:59.999). */
export function endOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59, 999)
}

export function addDays(date: Date, amount: number): Date {
  const d = new Date(date)
  d.setDate(d.getDate() + amount)
  return d
}

/**
 * Start of the week containing `date`.
 * @param weekStartsOn JS day: 0=Sunday … 6=Saturday (default 1=Monday)
 */
export function startOfWeek(date: Date, weekStartsOn = 1): Date {
  const d = startOfDay(date)
  const normalized = ((weekStartsOn % 7) + 7) % 7
  const day = d.getDay()
  const diff = (day - normalized + 7) % 7
  return addDays(d, -diff)
}

/** @deprecated Prefer startOfWeek(date, 1). Kept for existing call sites. */
export function startOfWeekMonday(date: Date): Date {
  return startOfWeek(date, 1)
}

export function endOfWeek(date: Date, weekStartsOn = 1): Date {
  const weekStart = startOfWeek(date, weekStartsOn)
  return new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + 6, 23, 59, 59)
}

export function endOfWeekMonday(date: Date): Date {
  return endOfWeek(date, 1)
}

export function endOfMonth(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth() + 1, 0, 23, 59, 59)
}

export function getMonthGridDays(anchor: Date, weekStartsOn = 1): Date[] {
  const firstDayOfMonth = new Date(anchor.getFullYear(), anchor.getMonth(), 1)
  const gridStart = startOfWeek(firstDayOfMonth, weekStartsOn)
  return Array.from({ length: 42 }, (_, i) => addDays(gridStart, i))
}

/** Local YYYY-MM-DD key (avoids UTC day-shift for midnight timestamps). */
export function dateKey(dateLike: Date | string): string {
  const d = typeof dateLike === 'string' ? new Date(dateLike) : dateLike
  const year = d.getFullYear()
  const month = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

export function isSameDay(a: Date, b: Date): boolean {
  return dateKey(a) === dateKey(b)
}

export function isMidnightLocal(dateLike: Date | string): boolean {
  const d = typeof dateLike === 'string' ? new Date(dateLike) : dateLike
  return d.getHours() === 0 && d.getMinutes() === 0 && d.getSeconds() === 0
}

export function toUiLocale(language?: string): string {
  if (!language) return 'ca-ES'
  if (language.startsWith('ca')) return 'ca-ES'
  if (language.startsWith('es')) return 'es-ES'
  return 'en-US'
}

export function formatShortRange(start: Date, end: Date, locale: string): string {
  const startLabel = new Intl.DateTimeFormat(locale, { day: 'numeric' }).format(start)
  const endLabel = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short' }).format(end)
  return `${startLabel}-${endLabel}`
}

export function groupEventsByDayKey<T extends { start: string | Date }>(
  events: T[],
): Map<string, T[]> {
  const grouped = new Map<string, T[]>()
  for (const event of events) {
    if (!event.start) continue
    const key = dateKey(event.start)
    const list = grouped.get(key) ?? []
    list.push(event)
    grouped.set(key, list)
  }
  for (const [, list] of grouped) {
    list.sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime())
  }
  return grouped
}

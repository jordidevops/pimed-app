function pad2(n: number): string {
  return String(n).padStart(2, '0')
}

export function toIsoDate(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`
}

export function isoWeekStart(isoDate: string): string {
  const d = new Date(`${isoDate}T12:00:00`)
  const dow = d.getDay()
  const diff = (dow + 6) % 7
  d.setDate(d.getDate() - diff)
  return toIsoDate(d)
}

export function isoWeekEnd(from: string): string {
  const d = new Date(`${from}T12:00:00`)
  d.setDate(d.getDate() + 6)
  return toIsoDate(d)
}

export function listIsoWeeksInMonth(
  year: number,
  month: number,
): Array<{ from: string; to: string }> {
  const monthStart = new Date(year, month - 1, 1)
  const monthEnd = new Date(year, month, 0)
  const weekStarts = new Set<string>()
  for (let d = new Date(monthStart); d <= monthEnd; d.setDate(d.getDate() + 1)) {
    weekStarts.add(isoWeekStart(toIsoDate(d)))
  }
  return [...weekStarts].sort().map((from) => ({ from, to: isoWeekEnd(from) }))
}

export function formatPeriodRangeDisplay(from: string, to: string): string {
  const startDate = new Date(`${from}T12:00:00`)
  const endDate = new Date(`${to}T12:00:00`)
  const sameMonth =
    startDate.getMonth() === endDate.getMonth() &&
    startDate.getFullYear() === endDate.getFullYear()

  if (sameMonth) {
    return `${startDate.toLocaleDateString('ca-ES', { day: 'numeric' })} – ${endDate.toLocaleDateString('ca-ES', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
    })}`
  }

  return `${startDate.toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
  })} – ${endDate.toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })}`
}

export function isPeriodConfirmed(
  confirmations: Array<{ period_from: string; period_to: string }>,
  from: string,
  to: string,
): boolean {
  return confirmations.some((c) => c.period_from === from && c.period_to === to)
}

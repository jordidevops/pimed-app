/** Format YYYY-MM-DD using tenant date pattern (dd/MM/yyyy, MM/dd/yyyy, yyyy-MM-dd). */
export function formatIsoDateWithPattern(isoDate: string, pattern: string): string {
  const parts = isoDate.slice(0, 10).split('-')
  if (parts.length !== 3) return isoDate
  const [yyyy, MM, dd] = parts
  return pattern
    .replace(/yyyy/g, yyyy)
    .replace(/MM/g, MM)
    .replace(/dd/g, dd)
}

/** Column order (JS DOW) starting from configured week start. */
export function weekColumnOrder(weekStartsOn: number): number[] {
  return Array.from({ length: 7 }, (_, i) => (weekStartsOn + i) % 7)
}

export function firstDayColumnOffset(year: number, month: number, weekStartsOn: number): number {
  const jsDay = new Date(year, month, 1).getDay()
  const order = weekColumnOrder(weekStartsOn)
  return order.indexOf(jsDay)
}

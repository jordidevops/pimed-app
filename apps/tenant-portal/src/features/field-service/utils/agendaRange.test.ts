import { describe, expect, it } from 'vitest'
import { getMonthGridDays, startOfWeekMonday } from '../../calendar/calendarDateUtils'
import { rangeForView } from './agendaRange'

describe('rangeForView', () => {
  it('month range covers the same days as the month grid (incl. week 5–11 Oct)', () => {
    const anchor = new Date(2026, 9, 5) // Mon 5 Oct 2026
    const { from, to } = rangeForView('month', anchor)
    const weekStart = startOfWeekMonday(anchor)
    const sample = new Date(2026, 9, 7, 10, 0, 0) // Wed in that week
    expect(sample.getTime()).toBeGreaterThanOrEqual(new Date(from).getTime())
    expect(sample.getTime()).toBeLessThan(new Date(to).getTime())

    const grid = getMonthGridDays(anchor)
    expect(localInRange(weekStart, from, to)).toBe(true)
    expect(localInRange(grid[0]!, from, to)).toBe(true)
    expect(localInRange(grid[grid.length - 1]!, from, to)).toBe(true)
  })

  it('week range is a subset of the month range for the same anchor', () => {
    const anchor = new Date(2026, 9, 5)
    const week = rangeForView('week', anchor)
    const month = rangeForView('month', anchor)
    expect(new Date(week.from).getTime()).toBeGreaterThanOrEqual(new Date(month.from).getTime())
    expect(new Date(week.to).getTime()).toBeLessThanOrEqual(new Date(month.to).getTime())
  })
})

function localInRange(day: Date, from: string, to: string): boolean {
  const start = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 12, 0, 0, 0)
  return start.getTime() >= new Date(from).getTime() && start.getTime() < new Date(to).getTime()
}

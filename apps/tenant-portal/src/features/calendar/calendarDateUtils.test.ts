import { describe, expect, it } from 'vitest'
import {
  dateKey,
  getMonthGridDays,
  groupEventsByDayKey,
  isMidnightLocal,
  startOfWeek,
  startOfWeekMonday,
} from './calendarDateUtils'

describe('calendarDateUtils', () => {
  it('groups events by local day and sorts by start', () => {
    const grouped = groupEventsByDayKey([
      { id: 'b', start: '2026-10-05T15:00:00' },
      { id: 'a', start: '2026-10-05T09:00:00' },
      { id: 'c', start: '2026-10-06T00:00:00' },
    ])
    expect([...grouped.keys()]).toEqual(['2026-10-05', '2026-10-06'])
    expect(grouped.get('2026-10-05')?.map((e) => e.id)).toEqual(['a', 'b'])
  })

  it('treats local midnight as all-day candidate', () => {
    expect(isMidnightLocal(new Date(2026, 9, 5, 0, 0, 0))).toBe(true)
    expect(isMidnightLocal(new Date(2026, 9, 5, 9, 30, 0))).toBe(false)
  })

  it('keeps local dateKey across week start helper', () => {
    const monday = startOfWeekMonday(new Date(2026, 9, 7)) // Wed
    expect(dateKey(monday)).toBe('2026-10-05')
  })

  it('respects weekStartsOn Sunday vs Monday', () => {
    const wed = new Date(2026, 9, 7) // Wed
    expect(dateKey(startOfWeek(wed, 1))).toBe('2026-10-05')
    expect(dateKey(startOfWeek(wed, 0))).toBe('2026-10-04')
  })

  it('builds month grids from the configured week start', () => {
    const mondayGrid = getMonthGridDays(new Date(2026, 9, 1), 1)
    const sundayGrid = getMonthGridDays(new Date(2026, 9, 1), 0)
    expect(dateKey(mondayGrid[0]!)).toBe('2026-09-28')
    expect(dateKey(sundayGrid[0]!)).toBe('2026-09-27')
  })
})

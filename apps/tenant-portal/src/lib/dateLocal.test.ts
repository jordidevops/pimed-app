import { describe, expect, it } from 'vitest'
import { localDayStartIso, localDaysHalfOpenRange } from './dateLocal'

describe('localDaysHalfOpenRange', () => {
  it('covers a single local day with exclusive end at next midnight', () => {
    const { from, to } = localDaysHalfOpenRange(1, '2026-06-15')
    const start = new Date(2026, 5, 15, 0, 0, 0, 0)
    const next = new Date(2026, 5, 16, 0, 0, 0, 0)
    expect(from).toBe(start.toISOString())
    expect(to).toBe(next.toISOString())
  })

  it('includes a local-midnight planned_start for the anchor day', () => {
    const planned = localDayStartIso('2026-06-15')
    const { from, to } = localDaysHalfOpenRange(1, '2026-06-15')
    const t = new Date(planned).getTime()
    expect(t).toBeGreaterThanOrEqual(new Date(from).getTime())
    expect(t).toBeLessThan(new Date(to).getTime())
  })

  it('covers 14 calendar days for list agenda windows', () => {
    const { from, to } = localDaysHalfOpenRange(14, '2026-06-15')
    expect(from).toBe(new Date(2026, 5, 15, 0, 0, 0, 0).toISOString())
    expect(to).toBe(new Date(2026, 5, 29, 0, 0, 0, 0).toISOString())
  })
})

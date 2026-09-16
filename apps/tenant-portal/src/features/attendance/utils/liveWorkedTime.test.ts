import { describe, expect, it } from 'vitest'
import { formatWorkedCounter, liveWorkedMs } from './liveWorkedTime'

describe('liveWorkedMs', () => {
  it('sums closed in/out pairs and an open interval', () => {
    const now = Date.parse('2026-09-15T10:30:00.000Z')
    const ms = liveWorkedMs(
      [
        { punch_type: 'in', occurred_at: '2026-09-15T08:00:00.000Z' },
        { punch_type: 'out', occurred_at: '2026-09-15T09:00:00.000Z' },
        { punch_type: 'in', occurred_at: '2026-09-15T10:00:00.000Z' },
      ],
      now,
    )
    expect(ms).toBe(90 * 60_000)
  })

  it('excludes pause time', () => {
    const now = Date.parse('2026-09-15T11:00:00.000Z')
    const ms = liveWorkedMs(
      [
        { punch_type: 'in', occurred_at: '2026-09-15T08:00:00.000Z' },
        { punch_type: 'break_start', occurred_at: '2026-09-15T10:00:00.000Z' },
        { punch_type: 'break_end', occurred_at: '2026-09-15T10:30:00.000Z' },
      ],
      now,
    )
    expect(ms).toBe(150 * 60_000)
  })
})

describe('formatWorkedCounter', () => {
  it('shows seconds only while running', () => {
    expect(formatWorkedCounter(90 * 60_000 + 5_000, false)).toBe('01:30')
    expect(formatWorkedCounter(90 * 60_000 + 5_000, true)).toBe('01:30:05')
  })
})

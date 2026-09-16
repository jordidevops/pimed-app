import { describe, expect, it } from 'vitest'
import { workLogRowSeconds } from './workLogDuration'

describe('work log duration', () => {
  it('uses exact timestamps instead of truncated duration_minutes', () => {
    expect(
      workLogRowSeconds({
        check_in: '2026-09-15T08:00:00.000Z',
        check_out: '2026-09-15T08:30:59.000Z',
        duration_minutes: 30,
      }),
    ).toBe(30 * 60 + 59)
  })

  it('falls back to duration_minutes when check_in is unavailable', () => {
    expect(
      workLogRowSeconds({
        check_in: null,
        check_out: '2026-09-15T08:30:00.000Z',
        duration_minutes: 30,
      }),
    ).toBe(30 * 60)
  })
})

import { describe, expect, it } from 'vitest'
import {
  evaluatePunchReminder,
  parsePunchReminderConfig,
  DEFAULT_PUNCH_REMINDER_CONFIG,
} from '../../../../../../supabase/functions/_shared/employee-portal/punch-reminder-eval.ts'

describe('parsePunchReminderConfig', () => {
  it('defaults to disabled', () => {
    expect(parsePunchReminderConfig(null).enabled).toBe(false)
  })

  it('reads enabled flag', () => {
    expect(parsePunchReminderConfig({ enabled: true }).enabled).toBe(true)
  })
})

describe('evaluatePunchReminder', () => {
  const workDay = {
    dayType: 'working',
    laborDayType: 'work',
    intervals: [{ start: '08:00', end: '14:00' }],
    holidayName: null,
    isAbsence: false,
  }

  it('returns null when reminders disabled path (vacation)', () => {
    const kind = evaluatePunchReminder({
      schedule: {
        dayType: 'vacation',
        laborDayType: 'vacation',
        intervals: [],
        holidayName: null,
        isAbsence: false,
      },
      punches: [],
      presenceStatus: 'outside',
      now: new Date('2026-07-13T10:00:00'),
      config: { ...DEFAULT_PUNCH_REMINDER_CONFIG, enabled: true, delayMinutes: 0 },
    })
    expect(kind).toBeNull()
  })

  it('detects missing entry after delay', () => {
    const kind = evaluatePunchReminder({
      schedule: workDay,
      punches: [],
      presenceStatus: 'outside',
      now: new Date('2026-07-13T08:10:00'),
      config: { ...DEFAULT_PUNCH_REMINDER_CONFIG, enabled: true, delayMinutes: 5 },
    })
    expect(kind).toBe('missing_entry')
  })

  it('waits until delay elapses', () => {
    const kind = evaluatePunchReminder({
      schedule: workDay,
      punches: [],
      presenceStatus: 'outside',
      now: new Date('2026-07-13T08:03:00'),
      config: { ...DEFAULT_PUNCH_REMINDER_CONFIG, enabled: true, delayMinutes: 5 },
    })
    expect(kind).toBeNull()
  })

  it('detects missing exit after last slot', () => {
    const kind = evaluatePunchReminder({
      schedule: workDay,
      punches: [{ punch_type: 'in', occurred_at: '2026-07-13T08:00:00Z' }],
      presenceStatus: 'working',
      now: new Date('2026-07-13T14:10:00'),
      config: { ...DEFAULT_PUNCH_REMINDER_CONFIG, enabled: true, delayMinutes: 5 },
    })
    expect(kind).toBe('missing_exit')
  })
})

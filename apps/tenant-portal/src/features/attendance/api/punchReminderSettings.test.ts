import { describe, expect, it } from 'vitest'
import {
  ATTENDANCE_PUNCH_REMINDERS_KEY,
  parsePunchReminderSettings,
  punchReminderSettingsPayload,
  PUNCH_REMINDER_SETTINGS_DEFAULTS,
} from '../api/punchReminderSettings'

describe('parsePunchReminderSettings', () => {
  it('returns defaults when missing', () => {
    expect(parsePunchReminderSettings({})).toEqual(PUNCH_REMINDER_SETTINGS_DEFAULTS)
  })

  it('reads flat attendance_punch_reminders key', () => {
    const parsed = parsePunchReminderSettings({
      [ATTENDANCE_PUNCH_REMINDERS_KEY]: {
        enabled: true,
        delay_minutes: 10,
        max_per_day: 2,
      },
    })
    expect(parsed.enabled).toBe(true)
    expect(parsed.delayMinutes).toBe(10)
    expect(parsed.maxPerDay).toBe(2)
  })

  it('reads nested attendance.punch_reminders fallback', () => {
    const parsed = parsePunchReminderSettings({
      attendance: {
        punch_reminders: {
          enabled: true,
          send_starting_soon: true,
        },
      },
    })
    expect(parsed.enabled).toBe(true)
    expect(parsed.sendStartingSoon).toBe(true)
  })
})

describe('punchReminderSettingsPayload', () => {
  it('writes flat key with snake_case fields', () => {
    const payload = punchReminderSettingsPayload({
      ...PUNCH_REMINDER_SETTINGS_DEFAULTS,
      enabled: true,
      delayMinutes: 15,
    })
    expect(payload).toEqual({
      [ATTENDANCE_PUNCH_REMINDERS_KEY]: {
        enabled: true,
        delay_minutes: 15,
        soon_threshold_minutes: 15,
        send_starting_soon: false,
        send_only_on_workdays: true,
        max_per_day: 4,
      },
    })
  })
})

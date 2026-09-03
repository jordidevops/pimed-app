export const ATTENDANCE_PUNCH_REMINDERS_KEY = 'attendance_punch_reminders'

export interface PunchReminderSettings {
  enabled: boolean
  delayMinutes: number
  soonThresholdMinutes: number
  sendStartingSoon: boolean
  sendOnlyOnWorkdays: boolean
  maxPerDay: number
}

export const PUNCH_REMINDER_SETTINGS_DEFAULTS: PunchReminderSettings = {
  enabled: false,
  delayMinutes: 5,
  soonThresholdMinutes: 15,
  sendStartingSoon: false,
  sendOnlyOnWorkdays: true,
  maxPerDay: 4,
}

export const PUNCH_REMINDER_DELAY_OPTIONS = [1, 5, 10, 15, 30] as const
export const PUNCH_REMINDER_SOON_OPTIONS = [5, 10, 15, 30] as const
export const PUNCH_REMINDER_MAX_PER_DAY_OPTIONS = [1, 2, 3, 4, 5, 6] as const

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const n = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(n)) return fallback
  return Math.max(min, Math.min(max, Math.floor(n)))
}

function readNested(raw: Record<string, unknown>): unknown {
  const flat = raw[ATTENDANCE_PUNCH_REMINDERS_KEY]
  if (flat && typeof flat === 'object') return flat

  const attendance = raw.attendance
  if (attendance && typeof attendance === 'object') {
    return (attendance as Record<string, unknown>).punch_reminders
  }

  return undefined
}

export function parsePunchReminderSettings(
  effective: Record<string, unknown> | undefined | null,
): PunchReminderSettings {
  const raw = effective ?? {}
  const o = readNested(raw)
  if (!o || typeof o !== 'object') {
    return { ...PUNCH_REMINDER_SETTINGS_DEFAULTS }
  }

  const cfg = o as Record<string, unknown>
  return {
    enabled: cfg.enabled === true,
    delayMinutes: clampInt(cfg.delay_minutes, 1, 120, PUNCH_REMINDER_SETTINGS_DEFAULTS.delayMinutes),
    soonThresholdMinutes: clampInt(
      cfg.soon_threshold_minutes,
      1,
      60,
      PUNCH_REMINDER_SETTINGS_DEFAULTS.soonThresholdMinutes,
    ),
    sendStartingSoon: cfg.send_starting_soon === true,
    sendOnlyOnWorkdays: cfg.send_only_on_workdays !== false,
    maxPerDay: clampInt(cfg.max_per_day, 1, 10, PUNCH_REMINDER_SETTINGS_DEFAULTS.maxPerDay),
  }
}

export function punchReminderSettingsPayload(
  settings: PunchReminderSettings,
): Record<string, unknown> {
  return {
    [ATTENDANCE_PUNCH_REMINDERS_KEY]: {
      enabled: settings.enabled,
      delay_minutes: settings.delayMinutes,
      soon_threshold_minutes: settings.soonThresholdMinutes,
      send_starting_soon: settings.sendStartingSoon,
      send_only_on_workdays: settings.sendOnlyOnWorkdays,
      max_per_day: settings.maxPerDay,
    },
  }
}

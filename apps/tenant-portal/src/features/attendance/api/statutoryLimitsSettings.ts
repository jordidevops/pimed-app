export type StatutoryOvertimePeriod = 'calendar_year' | 'rolling_12m' | 'fiscal_year'

export interface StatutoryLimitsSettings {
  maxOvertimeMinutesYear: number
  overtimePeriod: StatutoryOvertimePeriod
  fiscalYearStartMonth: number
  jurisdictionCode: string
  maxWorkMinutesYear: number | null
  alertThresholdsPct: number[]
  blockPunchOnLimit: boolean
}

const KEYS = {
  maxOvertime: 'attendance_statutory_max_overtime_minutes_year',
  period: 'attendance_statutory_overtime_period',
  fiscalMonth: 'attendance_statutory_fiscal_year_start_month',
  jurisdiction: 'attendance_statutory_jurisdiction_code',
  maxWork: 'attendance_statutory_max_work_minutes_year',
  thresholds: 'attendance_statutory_alert_thresholds_pct',
  blockPunch: 'attendance_statutory_block_punch_on_limit',
} as const

export const DEFAULT_STATUTORY: StatutoryLimitsSettings = {
  maxOvertimeMinutesYear: 4800,
  overtimePeriod: 'calendar_year',
  fiscalYearStartMonth: 1,
  jurisdictionCode: 'ES',
  maxWorkMinutesYear: null,
  alertThresholdsPct: [80, 90, 100],
  blockPunchOnLimit: false,
}

function parseThresholds(raw: unknown): number[] {
  if (Array.isArray(raw)) {
    return raw.map((v) => Number(v)).filter((n) => !Number.isNaN(n))
  }
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw) as unknown
      if (Array.isArray(parsed)) return parsed.map((v) => Number(v))
    } catch {
      return DEFAULT_STATUTORY.alertThresholdsPct
    }
  }
  return DEFAULT_STATUTORY.alertThresholdsPct
}

export function parseStatutoryLimits(
  effective: Record<string, unknown> | undefined | null,
): StatutoryLimitsSettings {
  const e = effective ?? {}
  const maxWork = e[KEYS.maxWork]
  return {
    maxOvertimeMinutesYear: Number(e[KEYS.maxOvertime] ?? DEFAULT_STATUTORY.maxOvertimeMinutesYear),
    overtimePeriod: (String(e[KEYS.period] ?? DEFAULT_STATUTORY.overtimePeriod) as StatutoryOvertimePeriod),
    fiscalYearStartMonth: Number(e[KEYS.fiscalMonth] ?? DEFAULT_STATUTORY.fiscalYearStartMonth),
    jurisdictionCode: String(e[KEYS.jurisdiction] ?? DEFAULT_STATUTORY.jurisdictionCode),
    maxWorkMinutesYear:
      maxWork === null || maxWork === undefined || maxWork === ''
        ? null
        : Number(maxWork),
    alertThresholdsPct: parseThresholds(e[KEYS.thresholds]),
    blockPunchOnLimit: e[KEYS.blockPunch] === true,
  }
}

export function statutoryLimitsPayload(
  settings: StatutoryLimitsSettings,
): Record<string, unknown> {
  return {
    [KEYS.maxOvertime]: settings.maxOvertimeMinutesYear,
    [KEYS.period]: settings.overtimePeriod,
    [KEYS.fiscalMonth]: settings.fiscalYearStartMonth,
    [KEYS.jurisdiction]: settings.jurisdictionCode,
    [KEYS.maxWork]: settings.maxWorkMinutesYear,
    [KEYS.thresholds]: settings.alertThresholdsPct,
    [KEYS.blockPunch]: settings.blockPunchOnLimit,
  }
}

export const OVERTIME_PERIOD_OPTIONS: { value: StatutoryOvertimePeriod; label: string }[] = [
  { value: 'calendar_year', label: 'Any natural' },
  { value: 'fiscal_year', label: 'Any fiscal' },
  { value: 'rolling_12m', label: '12 mesos rolling' },
]

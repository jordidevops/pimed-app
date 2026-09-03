export interface RetentionSettings {
  purgeEnabled: boolean
  retentionYears: number
}

export const RETENTION_MIN_YEARS = 4

export const DEFAULT_RETENTION: RetentionSettings = {
  purgeEnabled: false,
  retentionYears: RETENTION_MIN_YEARS,
}

const KEYS = {
  purgeEnabled: 'attendance_retention_purge_enabled',
  retentionYears: 'attendance_retention_years',
} as const

export function parseRetentionSettings(
  effective: Record<string, unknown> | undefined | null,
): RetentionSettings {
  const e = effective ?? {}
  const rawYears = Number(e[KEYS.retentionYears] ?? DEFAULT_RETENTION.retentionYears)
  const years = Number.isFinite(rawYears)
    ? Math.max(Math.trunc(rawYears), RETENTION_MIN_YEARS)
    : RETENTION_MIN_YEARS
  return {
    purgeEnabled: e[KEYS.purgeEnabled] === true,
    retentionYears: years,
  }
}

export function retentionSettingsPayload(
  settings: RetentionSettings,
): Record<string, unknown> {
  return {
    [KEYS.purgeEnabled]: settings.purgeEnabled,
    [KEYS.retentionYears]: Math.max(
      Math.trunc(settings.retentionYears) || RETENTION_MIN_YEARS,
      RETENTION_MIN_YEARS,
    ),
  }
}

export interface RetentionPurgeStatus {
  has_run: boolean
  id?: string
  cutoff_date?: string
  status?: 'running' | 'completed' | 'idle' | 'error'
  punches_deleted?: number
  entries_deleted?: number
  summaries_deleted?: number
  started_at?: string
  finished_at?: string | null
  error_message?: string | null
}

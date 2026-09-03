export const ATTENDANCE_ANOMALY_AUTOMATIONS_KEY = 'attendance_anomaly_automations'

export type AnomalyAutomationSettings = {
  enabled: boolean
  pauseNotClosed: boolean
  punchOutMissing: boolean
  overtimeThreshold: boolean
  shiftCoverageGap: boolean
  punchInUnusualHour: boolean
  absenceRequestPending: boolean
  monthClosedReport: boolean
}

export const ANOMALY_AUTOMATION_DEFAULTS: AnomalyAutomationSettings = {
  enabled: true,
  pauseNotClosed: true,
  punchOutMissing: true,
  overtimeThreshold: true,
  shiftCoverageGap: true,
  punchInUnusualHour: true,
  absenceRequestPending: true,
  monthClosedReport: true,
}

function readNested(raw: Record<string, unknown>): unknown {
  const flat = raw[ATTENDANCE_ANOMALY_AUTOMATIONS_KEY]
  if (flat && typeof flat === 'object') return flat
  const attendance = raw.attendance
  if (attendance && typeof attendance === 'object') {
    return (attendance as Record<string, unknown>).anomaly_automations
  }
  return undefined
}

export function parseAnomalyAutomationSettings(
  effective: Record<string, unknown> | undefined | null,
): AnomalyAutomationSettings {
  const o = readNested(effective ?? {})
  if (!o || typeof o !== 'object') {
    return { ...ANOMALY_AUTOMATION_DEFAULTS }
  }
  const cfg = o as Record<string, unknown>
  return {
    enabled: cfg.enabled !== false,
    pauseNotClosed: cfg.pause_not_closed !== false,
    punchOutMissing: cfg.punch_out_missing !== false,
    overtimeThreshold: cfg.overtime_threshold !== false,
    shiftCoverageGap: cfg.shift_coverage_gap !== false,
    punchInUnusualHour: cfg.punch_in_unusual_hour !== false,
    absenceRequestPending: cfg.absence_request_pending !== false,
    monthClosedReport: cfg.month_closed_report !== false,
  }
}

export function anomalyAutomationSettingsPayload(
  settings: AnomalyAutomationSettings,
): Record<string, unknown> {
  return {
    [ATTENDANCE_ANOMALY_AUTOMATIONS_KEY]: {
      enabled: settings.enabled,
      pause_not_closed: settings.pauseNotClosed,
      punch_out_missing: settings.punchOutMissing,
      overtime_threshold: settings.overtimeThreshold,
      shift_coverage_gap: settings.shiftCoverageGap,
      punch_in_unusual_hour: settings.punchInUnusualHour,
      absence_request_pending: settings.absenceRequestPending,
      month_closed_report: settings.monthClosedReport,
    },
  }
}

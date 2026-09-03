import type { TimePunch } from '../api/attendanceService'
import type { TimesheetDayRow } from '../api/timesheetService'
import { ANOMALY_UI } from './anomalyUi'

/** Incidències estructurals de fitxatge (més greus que retard/avanç horari). */
export const CRITICAL_PUNCH_ANOMALY_CODES = new Set([
  'MISSING_IN',
  'MISSING_OUT',
  'EXTRA_IN',
  'EXTRA_OUT',
  'BREAK_MISMATCH',
  'PAUSE_NOT_CLOSED',
  'DAY_NOT_CLOSED',
  'TRAVEL_NOT_CLOSED',
  'SEGMENT_GAP',
  'UNCLASSIFIED_GAP',
  'WORK_PROFILE_MISMATCH',
])

const PUNCH_STRUCTURAL_CODES = new Set([
  'MISSING_IN',
  'MISSING_OUT',
  'EXTRA_IN',
  'EXTRA_OUT',
])

export function isTimesheetMissingRecordDay(day: TimesheetDayRow): boolean {
  return (
    day.payroll_action === 'missing_punch' &&
    !day.absence_id &&
    day.punch_count === 0 &&
    day.worked_minutes === 0
  )
}

export function anomalyLabel(
  code: string,
  t: (key: string, fallback: string) => string,
): string {
  const meta = ANOMALY_UI[code]
  return meta ? t(meta.labelKey, meta.labelFallback) : code
}

export function anomalyHelp(
  code: string,
  t: (key: string, fallback: string) => string,
): string | null {
  const meta = ANOMALY_UI[code]
  if (!meta?.helpKey) return null
  return t(meta.helpKey, meta.helpFallback ?? meta.labelFallback)
}

/** Marca incidències crítiques per fitxatge (id → codi). */
export function resolvePunchCriticalMarkers(
  punches: TimePunch[],
  anomalyCodes: string[] | null | undefined,
  entryStatus: string | null | undefined,
): Map<string, string> {
  const markers = new Map<string, string>()
  const codes = new Set(anomalyCodes ?? [])

  const sorted = [...punches].sort((a, b) =>
    (a.occurred_at ?? '').localeCompare(b.occurred_at ?? ''),
  )

  const inPunches = sorted.filter((p) => p.punch_type === 'in' && p.id)
  const outPunches = sorted.filter((p) => p.punch_type === 'out' && p.id)

  if (
    (entryStatus === 'open' || codes.has('MISSING_OUT')) &&
    inPunches.length > 0 &&
    outPunches.length === 0
  ) {
    const lastIn = inPunches[inPunches.length - 1]!
    markers.set(lastIn.id!, 'MISSING_OUT')
  }

  let inCount = 0
  let outCount = 0
  for (const punch of sorted) {
    if (!punch.id) continue
    if (punch.punch_type === 'in') {
      inCount += 1
      if (codes.has('EXTRA_IN') && inCount > outCount + 1) {
        markers.set(punch.id, 'EXTRA_IN')
      }
    }
    if (punch.punch_type === 'out') {
      outCount += 1
      if (outCount > inCount) {
        if (codes.has('MISSING_IN')) {
          markers.set(punch.id, 'MISSING_IN')
        } else if (codes.has('EXTRA_OUT')) {
          markers.set(punch.id, 'EXTRA_OUT')
        }
      }
    }
  }

  return markers
}

/** Incidències crítiques del dia sense icona per fitxatge (pauses, jornada mòbil, etc.). */
export function resolveDayLevelCriticalAnomalies(
  anomalyCodes: string[] | null | undefined,
  punchMarkers: Map<string, string>,
): string[] {
  const attachedCodes = new Set(punchMarkers.values())

  return (anomalyCodes ?? []).filter((code) => {
    if (!CRITICAL_PUNCH_ANOMALY_CODES.has(code)) return false
    if (PUNCH_STRUCTURAL_CODES.has(code)) {
      return attachedCodes.has(code) ? false : attachedCodes.size === 0
    }
    return true
  })
}

import type { WorkInterval } from '../api/workIntervals'
import { isWorkLaborDay, type ResolvedWorkDay } from '../api/workDayResolveService'

import { DEFAULT_PUNCH_DISCREPANCY_TOLERANCE_MIN } from '../api/punchDiscrepancySettings'

export const PUNCH_DISCREPANCY_TOLERANCE_MIN = DEFAULT_PUNCH_DISCREPANCY_TOLERANCE_MIN

export type PunchDiscrepancyHint =
  | 'outside_schedule'
  | 'geo_imprecise'
  | 'late_punch_out'
  | 'early_punch_out'
  | 'early_punch_in'
  | 'no_schedule_work'

export type PunchDiscrepancyResolution =
  | 'confirmed_ok'
  | 'strip_geo'
  | 'overtime_claimed'
  | 'scheduled_hours_claimed'

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number)
  return h * 60 + m
}

function normEnd(start: string, end: string): number {
  const s = toMinutes(start)
  const e = toMinutes(end)
  return e <= s ? e + 24 * 60 : e
}

/** True when punch local time falls inside any scheduled slot (± tolerance). */
export function isPunchWithinSchedule(
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): boolean {
  if (intervals.length === 0) return true

  const punchMin = occurredAt.getHours() * 60 + occurredAt.getMinutes()

  return intervals.some((iv) => {
    const startMin = toMinutes(iv.start) - toleranceMinutes
    const endMin = normEnd(iv.start, iv.end) + toleranceMinutes
    if (endMin > 24 * 60) {
      return punchMin >= startMin || punchMin <= endMin - 24 * 60
    }
    return punchMin >= startMin && punchMin <= endMin
  })
}

export function isLatePunchOut(
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): boolean {
  if (intervals.length === 0) return false
  const last = intervals[intervals.length - 1]
  const endMin = normEnd(last.start, last.end)
  const punchMin = occurredAt.getHours() * 60 + occurredAt.getMinutes()
  return punchMin > endMin + toleranceMinutes
}

export function isEarlyPunchOut(
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): boolean {
  if (intervals.length === 0) return false
  const last = intervals[intervals.length - 1]
  const endMin = normEnd(last.start, last.end)
  const punchMin = occurredAt.getHours() * 60 + occurredAt.getMinutes()
  return punchMin < endMin - toleranceMinutes
}

export function isEarlyPunchIn(
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): boolean {
  if (intervals.length === 0) return false
  const first = intervals[0]
  const punchMin = occurredAt.getHours() * 60 + occurredAt.getMinutes()
  return punchMin < toMinutes(first.start) - toleranceMinutes
}

export function isLatePunchIn(
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): boolean {
  if (intervals.length === 0) return false
  const first = intervals[0]
  const punchMin = occurredAt.getHours() * 60 + occurredAt.getMinutes()
  return punchMin > toMinutes(first.start) + toleranceMinutes
}

/** Retard o avanç respecte l'horari assignat (només entrada/sortida de jornada). */
export function hasScheduleTimingAlert(
  punchType: string,
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): boolean {
  if (intervals.length === 0) return false
  if (punchType === 'in' || punchType === 'day_start') {
    return (
      isEarlyPunchIn(occurredAt, intervals, toleranceMinutes)
      || isLatePunchIn(occurredAt, intervals, toleranceMinutes)
    )
  }
  if (punchType === 'out' || punchType === 'day_end') {
    return (
      isEarlyPunchOut(occurredAt, intervals, toleranceMinutes)
      || isLatePunchOut(occurredAt, intervals, toleranceMinutes)
    )
  }
  return false
}

export type ScheduleTimingAlertKind = 'early_in' | 'late_in' | 'early_out' | 'late_out'

export function resolveScheduleTimingAlert(
  punchType: string,
  occurredAt: Date,
  intervals: WorkInterval[],
  toleranceMinutes = PUNCH_DISCREPANCY_TOLERANCE_MIN,
): ScheduleTimingAlertKind | null {
  if (intervals.length === 0) return null
  if (punchType === 'in' || punchType === 'day_start') {
    if (isEarlyPunchIn(occurredAt, intervals, toleranceMinutes)) return 'early_in'
    if (isLatePunchIn(occurredAt, intervals, toleranceMinutes)) return 'late_in'
    return null
  }
  if (punchType === 'out' || punchType === 'day_end') {
    if (isEarlyPunchOut(occurredAt, intervals, toleranceMinutes)) return 'early_out'
    if (isLatePunchOut(occurredAt, intervals, toleranceMinutes)) return 'late_out'
    return null
  }
  return null
}

/** Dia sense franges horàries assignades (festiu, no laborable, o laborable sense torns). */
export function isUnscheduledWorkDay(schedule: ResolvedWorkDay | null): boolean {
  if (!schedule) return false
  if (!isWorkLaborDay(schedule)) return true
  return schedule.intervals.length === 0
}

export function detectPunchDiscrepancyHints(params: {
  punchType: 'in' | 'out'
  occurredAt: Date
  schedule: ResolvedWorkDay | null
  anomalyCodes: string[]
  hadGeo: boolean
  toleranceMinutes?: number
}): PunchDiscrepancyHint[] {
  const hints: PunchDiscrepancyHint[] = []
  const tolerance = params.toleranceMinutes ?? PUNCH_DISCREPANCY_TOLERANCE_MIN
  const { punchType, occurredAt, schedule, anomalyCodes, hadGeo } = params

  if (anomalyCodes.includes('HIGH_UNCERTAINTY') || (hadGeo && anomalyCodes.includes('GEOFENCE_WARN'))) {
    hints.push('geo_imprecise')
  }

  if (!schedule || !isWorkLaborDay(schedule) || schedule.intervals.length === 0) {
    if (punchType === 'out' && isUnscheduledWorkDay(schedule)) {
      hints.push('no_schedule_work')
    }
    return hints
  }

  if (!isPunchWithinSchedule(occurredAt, schedule.intervals, tolerance)) {
    hints.push('outside_schedule')
  }
  if (punchType === 'out' && isLatePunchOut(occurredAt, schedule.intervals, tolerance)) {
    hints.push('late_punch_out')
  }
  if (punchType === 'out' && isEarlyPunchOut(occurredAt, schedule.intervals, tolerance)) {
    hints.push('early_punch_out')
  }
  if (punchType === 'in' && isEarlyPunchIn(occurredAt, schedule.intervals, tolerance)) {
    hints.push('early_punch_in')
  }

  return hints
}

export function shouldPromptPunchDiscrepancy(
  hints: PunchDiscrepancyHint[],
  anomalyCodes: string[],
): boolean {
  if (hints.length > 0) return true
  return anomalyCodes.some((code) =>
    ['HIGH_UNCERTAINTY', 'GEOFENCE_WARN', 'GEOFENCE_BLOCK'].includes(code),
  )
}

export function availableDiscrepancyResolutions(params: {
  hints: PunchDiscrepancyHint[]
  punchType: 'in' | 'out'
  hadGeo: boolean
  anomalyCodes: string[]
}): PunchDiscrepancyResolution[] {
  const options: PunchDiscrepancyResolution[] = ['confirmed_ok']
  const { hints, punchType, hadGeo, anomalyCodes } = params

  if (
    hadGeo
    && (hints.includes('geo_imprecise') || anomalyCodes.includes('HIGH_UNCERTAINTY'))
  ) {
    options.push('strip_geo')
  }

  if (hints.includes('late_punch_out') || hints.includes('no_schedule_work')) {
    options.push('overtime_claimed')
  }

  if (
    hints.includes('outside_schedule')
    || hints.includes('early_punch_in')
    || hints.includes('early_punch_out')
    || hints.includes('late_punch_out')
  ) {
    options.push('scheduled_hours_claimed')
  }

  return options
}

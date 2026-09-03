import type { PayrollReviewDay } from '../api/payrollReviewService'
import type { TimesheetDayRow } from '../api/timesheetService'

export const OVERTIME_CLAIMED_ANOMALY = 'OVERTIME_CLAIMED'

export function dayHasOvertimeClaimed(anomalies: string[] | null | undefined): boolean {
  return anomalies?.includes(OVERTIME_CLAIMED_ANOMALY) ?? false
}

export function isOvertimeAttentionDay(day: {
  overtime_minutes?: number
  anomalies?: string[] | null
  anomaly_codes?: string[] | null
}): boolean {
  if ((day.overtime_minutes ?? 0) > 0) return true
  const codes = day.anomalies ?? day.anomaly_codes ?? []
  return dayHasOvertimeClaimed(codes)
}

export function sumOvertimeMinutes(
  days: Array<{ overtime_minutes?: number }>,
): number {
  return days.reduce((sum, d) => sum + (d.overtime_minutes ?? 0), 0)
}

export function countOvertimeAttentionDays(days: PayrollReviewDay[]): number {
  return days.filter((d) => isOvertimeAttentionDay(d)).length
}

export function payrollReviewOvertimeStats(days: PayrollReviewDay[]) {
  const attentionDays = days.filter((d) => isOvertimeAttentionDay(d))
  const claimedDays = days.filter((d) => dayHasOvertimeClaimed(d.anomalies))
  return {
    totalMinutes: sumOvertimeMinutes(days),
    attentionCount: attentionDays.length,
    claimedCount: claimedDays.length,
    attentionDays,
  }
}

export function timesheetOvertimeStats(days: TimesheetDayRow[]) {
  return {
    totalMinutes: sumOvertimeMinutes(days),
    attentionCount: days.filter((d) => isOvertimeAttentionDay(d)).length,
  }
}

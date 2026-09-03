import type { PunchDiscrepancyRecord } from '../api/dayDetailService'
import type { ApprovalAssistSettings } from '../api/approvalAssistSettings'
import type { PayrollReviewDay } from '../api/payrollReviewService'
import type { AttendanceDayDetail } from '../api/dayDetailService'
import { isMobileWorkProfile } from './punchProfileUi'

export const SCHEDULE_HOURS_CLAIMED_ANOMALY = 'SCHEDULE_HOURS_CLAIMED'

export function hasScheduleHoursClaim(
  anomalies: string[],
  declarations?: PunchDiscrepancyRecord[],
): boolean {
  if (anomalies.includes(SCHEDULE_HOURS_CLAIMED_ANOMALY)) return true
  return declarations?.some((d) => d.resolution === 'scheduled_hours_claimed') ?? false
}

export function hasBlockingAnomaliesForTrust(anomalies: string[]): boolean {
  return anomalies.some((code) => code !== SCHEDULE_HOURS_CLAIMED_ANOMALY)
}

export interface TrustApprovalEligibilityInput {
  trustEnabled: boolean
  effectiveTimeEnabled?: boolean
  anomalies: string[]
  declarations?: PunchDiscrepancyRecord[]
  summaryStatus: string | null
  payrollLocked: boolean
  provisional: boolean
  entryStatus: string | null
  workedMinutes: number
  effectiveMinutes?: number | null
  paidMinutes?: number | null
  workProfile?: string | null
  expectedMinutes: number
  toleranceMinutes: number
  payrollAction?: PayrollReviewDay['payroll_action']
}

/** Minuts a comparar amb l'horari previst (E6): efectiu (fixed_site) o remunerable (mobile) si flag actiu. */
export function trustComparisonMinutes(input: {
  effectiveTimeEnabled?: boolean
  effectiveMinutes?: number | null
  paidMinutes?: number | null
  workProfile?: string | null
  workedMinutes: number
}): number {
  if (input.effectiveTimeEnabled) {
    if (
      isMobileWorkProfile(input.workProfile ?? null) &&
      input.paidMinutes != null &&
      input.paidMinutes > 0
    ) {
      return input.paidMinutes
    }
    if (input.effectiveMinutes != null && input.effectiveMinutes > 0) {
      return input.effectiveMinutes
    }
  }
  return input.workedMinutes
}

export function isTrustScheduleHoursApprovalEligible(
  input: TrustApprovalEligibilityInput,
): boolean {
  if (!input.trustEnabled) return false
  if (!hasScheduleHoursClaim(input.anomalies, input.declarations)) return false
  if (hasBlockingAnomaliesForTrust(input.anomalies)) return false
  if (input.payrollLocked) return false
  if (input.provisional) return false
  if (input.summaryStatus !== 'draft') return false
  if (input.entryStatus === 'open') return false
  if (input.payrollAction === 'missing_punch') return false

  const comparedMinutes = trustComparisonMinutes({
    effectiveTimeEnabled: input.effectiveTimeEnabled,
    effectiveMinutes: input.effectiveMinutes,
    paidMinutes: input.paidMinutes,
    workProfile: input.workProfile,
    workedMinutes: input.workedMinutes,
  })
  const workedDiff = Math.abs(comparedMinutes - input.expectedMinutes)
  if (input.expectedMinutes > 0 && workedDiff > input.toleranceMinutes) return false

  return true
}

export function isDayDetailTrustApprovalEligible(
  detail: AttendanceDayDetail,
  settings: ApprovalAssistSettings,
): boolean {
  return isTrustScheduleHoursApprovalEligible({
    trustEnabled: settings.trustScheduleHoursClaim,
    effectiveTimeEnabled: settings.effectiveTimeEnabled,
    anomalies: detail.anomaly_codes,
    declarations: detail.punch_discrepancies,
    summaryStatus: detail.summary?.status ?? null,
    payrollLocked: Boolean(detail.summary?.payroll_locked_at),
    provisional: detail.provisional,
    entryStatus: detail.entry?.status ?? detail.provisional_entry?.status ?? null,
    workedMinutes: detail.summary?.worked_minutes ?? detail.entry?.net_minutes ?? 0,
    effectiveMinutes: (detail.summary as { effective_minutes?: number | null } | null)
      ?.effective_minutes,
    paidMinutes: (detail.summary as { paid_minutes?: number | null } | null)?.paid_minutes,
    workProfile:
      (detail.summary as { work_profile_snapshot?: string | null } | null)
        ?.work_profile_snapshot ?? null,
    expectedMinutes: detail.summary?.expected_minutes ?? 0,
    toleranceMinutes: settings.toleranceMinutes,
  })
}

export function isPayrollReviewDayTrustEligible(
  day: PayrollReviewDay,
  settings: ApprovalAssistSettings,
): boolean {
  return isTrustScheduleHoursApprovalEligible({
    trustEnabled: settings.trustScheduleHoursClaim,
    effectiveTimeEnabled: settings.effectiveTimeEnabled,
    anomalies: day.anomalies,
    summaryStatus: day.summary_status,
    payrollLocked: day.payroll_locked,
    provisional: false,
    entryStatus: day.entry_status,
    workedMinutes: day.worked_minutes,
    effectiveMinutes: day.effective_minutes,
    paidMinutes: day.paid_minutes,
    workProfile: day.work_profile_snapshot,
    expectedMinutes: day.expected_minutes,
    toleranceMinutes: settings.toleranceMinutes,
    payrollAction: day.payroll_action,
  })
}

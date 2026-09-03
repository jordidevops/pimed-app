import type { TimeDailySummary } from '../api/timesheetService'

export function hasEffectiveTimeBuckets(summary: TimeDailySummary | null | undefined): boolean {
  if (!summary) return false
  return (
    summary.effective_minutes != null ||
    summary.presence_minutes != null ||
    summary.paid_minutes != null ||
    summary.work_minutes != null
  )
}

export function isMobileWorkProfileSnapshot(profile: string | null | undefined): boolean {
  return (
    profile === 'mobile_peripatetic' ||
    profile === 'hybrid' ||
    profile === 'delivery'
  )
}

/** Columna 2: presència (camp) o net legacy (oficina). */
export function presenceOrNetMinutes(summary: TimeDailySummary): number {
  const mobile = isMobileWorkProfileSnapshot(summary.work_profile_snapshot)
  if (mobile && summary.presence_minutes != null) {
    return summary.presence_minutes
  }
  return summary.worked_minutes ?? 0
}

export function shouldShowPaidColumn(summary: TimeDailySummary): boolean {
  if (summary.paid_minutes == null || summary.effective_minutes == null) return false
  const mobile = isMobileWorkProfileSnapshot(summary.work_profile_snapshot)
  if (mobile) return true
  return summary.paid_minutes !== summary.effective_minutes
}

export function consolidationSkippedReason(
  meta: unknown,
): string | null {
  if (!meta || typeof meta !== 'object') return null
  const skipped = (meta as Record<string, unknown>).skipped
  return typeof skipped === 'string' ? skipped : null
}

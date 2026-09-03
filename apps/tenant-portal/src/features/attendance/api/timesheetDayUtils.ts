import type { TimesheetDayRow } from './timesheetService'

export function isTimesheetReviewPendingDay(day: TimesheetDayRow): boolean {
  return Boolean(day.needs_review || day.status === 'draft' || day.payroll_action === 'blocked')
}

export type TimesheetDayVisualKind =
  | 'it'
  | 'absence'
  | 'holiday'
  | 'non_working'
  | 'missing_punch'
  | 'worked'
  | 'pending'
  | 'blocked'
  | 'neutral'

export function resolveTimesheetDayVisualKind(day: TimesheetDayRow): TimesheetDayVisualKind {
  if (day.is_it && day.absence_id) return 'it'
  if (day.absence_id) return 'absence'
  if (day.payroll_action === 'blocked' || day.needs_review) return 'blocked'
  const hasPunchActivity = day.punch_count > 0 || day.worked_minutes > 0
  if (hasPunchActivity) return 'worked'
  if (day.payroll_action === 'missing_punch') return 'missing_punch'
  if (day.day_type === 'holiday' || day.day_type === 'half_holiday') return 'holiday'
  if (day.day_type === 'non_working' || day.day_type === 'absence') return 'non_working'
  if (day.is_laborable) return 'pending'
  return 'neutral'
}

/** Alineat amb LaborCalendarGrid: verd laborable, vermell festiu, taronja sense registre. */
export const TIMESHEET_DAY_CARD_CLASS: Record<TimesheetDayVisualKind, string> = {
  it: 'border-violet-300 bg-violet-50/80',
  absence: 'border-sky-300 bg-sky-50/80',
  holiday:
    'border-red-300 bg-red-50/70 [background-image:repeating-linear-gradient(-45deg,transparent,transparent_3px,rgba(0,0,0,.04)_3px,rgba(0,0,0,.04)_6px)]',
  non_working: 'border-slate-300 bg-slate-50/50 border-dashed',
  missing_punch: 'border-orange-400 bg-orange-50/80 border-dashed',
  worked: 'border-emerald-300 bg-emerald-50/70',
  pending: 'border-emerald-200 bg-emerald-50/40 border-dashed',
  blocked: 'border-amber-300 bg-amber-50/70',
  neutral: 'border-border/60 bg-muted/20',
}

export function timesheetDayTypeLabelKey(dayType: string | null | undefined): string {
  return `payroll_review.day_type.${dayType ?? 'unknown'}`
}

export function timesheetDayKindLabelKey(kind: TimesheetDayVisualKind): string {
  return `timesheet.legend.${kind}`
}

export function emptyTimesheetDay(date: string): TimesheetDayRow {
  return {
    work_date: date,
    worked_minutes: 0,
    expected_minutes: null,
    punch_count: 0,
    status: null,
    needs_review: false,
    anomaly_codes: null,
    source: 'empty',
    day_type: 'unknown',
    is_laborable: false,
  }
}

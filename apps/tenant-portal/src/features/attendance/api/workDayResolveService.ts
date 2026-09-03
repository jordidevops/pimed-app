import { supabase } from '@/lib/supabase'
import { toLocalIsoDate } from './schedulePlannerService'
import {
  formatIntervalsList,
  formatWorkDuration,
  parseWorkIntervals,
  totalWorkMinutes,
  type WorkInterval,
} from './workIntervals'

export interface ResolvedWorkDay {
  date: string
  dayType: string
  laborDayType: string | null
  expectedMinutes: number
  intervals: WorkInterval[]
  holidayName: string | null
  isAbsence: boolean
}

function normalizeTimeValue(raw: unknown): string {
  const s = String(raw ?? '')
  if (!s) return ''
  const parts = s.split(':')
  if (parts.length < 2) return s.slice(0, 5)
  return `${parts[0].padStart(2, '0')}:${parts[1].padStart(2, '0')}`
}

export function parseResolveWorkDay(raw: unknown, date: string): ResolvedWorkDay {
  const row = (raw ?? {}) as Record<string, unknown>
  let intervals = parseWorkIntervals(row.work_intervals)
  if (intervals.length === 0 && row.shift_start_time && row.shift_end_time) {
    intervals = [{
      start: normalizeTimeValue(row.shift_start_time),
      end: normalizeTimeValue(row.shift_end_time),
    }]
  }

  return {
    date,
    dayType: String(row.day_type ?? 'unknown'),
    laborDayType: row.labor_day_type != null ? String(row.labor_day_type) : null,
    expectedMinutes: Number(row.expected_minutes ?? 0),
    intervals,
    holidayName: row.holiday_name != null ? String(row.holiday_name) : null,
    isAbsence: Boolean(row.is_absence),
  }
}

export async function fetchResolveWorkDay(
  employeeId: string,
  workDate: string,
): Promise<ResolvedWorkDay> {
  const { data, error } = await supabase.rpc('resolve_work_day', {
    p_employee_id: employeeId,
    p_work_date: workDate,
  })
  if (error) throw error
  return parseResolveWorkDay(data, workDate)
}

export function addDaysIso(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T12:00:00`)
  d.setDate(d.getDate() + days)
  return toLocalIsoDate(d)
}

export function isWorkLaborDay(day: ResolvedWorkDay): boolean {
  return day.laborDayType === 'work' || day.dayType === 'working'
}

/** Minutes from midnight for the end of the last work slot today. */
export function lastScheduleEndMinutes(intervals: WorkInterval[]): number | null {
  if (intervals.length === 0) return null
  const last = intervals[intervals.length - 1]
  const [sh, sm] = last.start.split(':').map(Number)
  const [eh, em] = last.end.split(':').map(Number)
  const startMin = sh * 60 + sm
  let endMin = eh * 60 + em
  if (endMin <= startMin) endMin += 24 * 60
  return endMin % (24 * 60)
}

/** True when now is within `leadMinutes` of the last scheduled end (or after it). */
export function isNearOrPastScheduleEnd(
  intervals: WorkInterval[],
  now: Date,
  leadMinutes = 30,
): boolean {
  const endMin = lastScheduleEndMinutes(intervals)
  if (endMin == null) return false
  const nowMin = now.getHours() * 60 + now.getMinutes()
  return nowMin >= endMin - leadMinutes
}

export function formatDayScheduleLabel(
  day: ResolvedWorkDay,
  overnightSuffix: string,
): string {
  if (isWorkLaborDay(day) && day.intervals.length > 0) {
    const hours = formatWorkDuration(
      day.expectedMinutes > 0 ? day.expectedMinutes : totalWorkMinutes(day.intervals),
    )
    return `${formatIntervalsList(day.intervals, overnightSuffix)} · ${hours}`
  }
  if (day.holidayName) return day.holidayName
  if (day.laborDayType === 'vacation') return 'vacation'
  if (day.laborDayType === 'leave') return 'leave'
  if (day.laborDayType === 'holiday' || day.dayType === 'holiday') return 'holiday'
  return 'off'
}

export function formatWorkDayDate(isoDate: string, locale = 'ca-ES'): string {
  const d = new Date(`${isoDate}T12:00:00`)
  return d.toLocaleDateString(locale, {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
  })
}

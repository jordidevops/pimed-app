import { supabase } from '@/lib/supabase'
import type { TimeEntry, TimePunch } from './attendanceService'
import { fetchActivitySegments, type ActivitySegment } from './activitySegmentService'
import { buildRecordRowsFromPunches, punchWorkDate } from './recordRows'
import type { TimeDailySummary } from './timesheetService'

export type DayDetailProvisionalReason = 'no_entry' | 'open_day' | 'no_summary'

export interface PunchDiscrepancyRecord {
  id: string
  punch_id: string
  resolution: string
  note: string | null
  context: Record<string, unknown> | null
  created_at: string
}

export interface AttendanceDayDetail {
  employee_id: string
  work_date: string
  punches: TimePunch[]
  entry: TimeEntry | null
  summary: TimeDailySummary | null
  provisional: boolean
  provisional_reason: DayDetailProvisionalReason | null
  /** Hores estimades des de fitxatges quan encara no hi ha registre processat. */
  provisional_entry: TimeEntry | null
  anomaly_codes: string[]
  punch_discrepancies: PunchDiscrepancyRecord[]
  activity_segments: ActivitySegment[]
}

function uniqueCodes(codes: (string | null | undefined)[]): string[] {
  return [...new Set(codes.filter((c): c is string => Boolean(c)))]
}

function resolveProvisional(
  punches: TimePunch[],
  entry: TimeEntry | null,
  summary: TimeDailySummary | null,
): { provisional: boolean; reason: DayDetailProvisionalReason | null } {
  if (punches.length === 0) {
    return { provisional: false, reason: null }
  }
  if (!entry) {
    return { provisional: true, reason: 'no_entry' }
  }
  if (entry.status === 'open') {
    return { provisional: true, reason: 'open_day' }
  }
  if (!summary) {
    return { provisional: true, reason: 'no_summary' }
  }
  return { provisional: false, reason: null }
}

/** Carrega raw punches, time_entry i summary per a un dia concret. */
export async function fetchAttendanceDayDetail(
  employeeId: string,
  workDate: string,
): Promise<AttendanceDayDetail> {
  const dayStart = `${workDate}T00:00:00`
  const dayEnd = `${workDate}T23:59:59.999`

  const [punchesRes, entryRes, summaryRes, activity_segments] = await Promise.all([
    supabase
      .from('time_punches')
      .select('*')
      .eq('employee_id', employeeId)
      .gte('occurred_at', dayStart)
      .lte('occurred_at', dayEnd)
      .order('occurred_at', { ascending: true }),
    supabase
      .from('time_entries')
      .select('*')
      .eq('employee_id', employeeId)
      .eq('work_date', workDate)
      .maybeSingle(),
    supabase
      .from('time_daily_summaries')
      .select('*')
      .eq('employee_id', employeeId)
      .eq('work_date', workDate)
      .maybeSingle(),
    fetchActivitySegments(employeeId, workDate),
  ])

  if (punchesRes.error) throw new Error(punchesRes.error.message)
  if (entryRes.error) throw new Error(entryRes.error.message)
  if (summaryRes.error) throw new Error(summaryRes.error.message)

  const allPunches = (punchesRes.data ?? []) as TimePunch[]
  const punches = allPunches.filter(
    (p) => p.occurred_at && punchWorkDate(p.occurred_at) === workDate,
  )
  const punchIds = punches.map((p) => p.id).filter((id): id is string => Boolean(id))

  let punch_discrepancies: PunchDiscrepancyRecord[] = []
  if (punchIds.length > 0) {
    const discRes = await supabase
      .from('attendance_punch_discrepancies' as never)
      .select('id, punch_id, resolution, note, context, created_at')
      .in('punch_id' as never, punchIds)
      .order('created_at', { ascending: true })
    if (discRes.error) throw new Error(discRes.error.message)
    punch_discrepancies = (discRes.data ?? []) as PunchDiscrepancyRecord[]
  }

  const entry = (entryRes.data as TimeEntry | null) ?? null
  const summary = (summaryRes.data as TimeDailySummary | null) ?? null

  const { provisional, reason } = resolveProvisional(punches, entry, summary)

  const provisional_entry =
    provisional && !entry && punches.length > 0
      ? (buildRecordRowsFromPunches(punches).find((r) => r.work_date === workDate) ?? null)
      : null

  const anomaly_codes = uniqueCodes([
    ...(summary?.anomaly_codes ?? []),
    ...punches.flatMap((p) => p.anomaly_codes ?? []),
  ])

  return {
    employee_id: employeeId,
    work_date: workDate,
    punches,
    entry,
    summary,
    provisional,
    provisional_reason: reason,
    provisional_entry,
    anomaly_codes,
    punch_discrepancies,
    activity_segments,
  }
}

export function formatDayDetailTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('ca-ES', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'Europe/Madrid',
  })
}

export function formatWorkDateLabel(workDate: string): string {
  return new Date(`${workDate}T12:00:00`).toLocaleDateString('ca-ES', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })
}

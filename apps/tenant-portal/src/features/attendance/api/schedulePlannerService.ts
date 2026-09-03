import { supabase } from '@/lib/supabase'
import type { TenantDayType } from './useLaborCalendar'
import { parseWorkIntervals, type WorkInterval } from './workIntervals'
import type { ResolvedDay } from '../components/LaborCalendarGrid'

export type PlannerScope = 'tenant' | 'site' | 'employee' | 'group'

export interface PlannerDayRecord {
  scope: PlannerScope
  employee_id: string | null
  site_id: string | null
  employee_name: string | null
  department_id: string | null
  calendar_group_id: string | null
  date: string
  day_type: TenantDayType
  day_name: string | null
  work_intervals: WorkInterval[]
  planned_minutes: number
  source: string
}

export interface PlannerActualRecord {
  employee_id: string
  work_date: string
  worked_minutes: number
  punch_count: number
  needs_review: boolean
  anomaly_codes: string[] | null
  status: string | null
}

export interface PlannerGridRow {
  id: string
  scope: PlannerScope
  label: string
  employeeId?: string
  departmentId?: string | null
  calendarGroupId?: string | null
  days: Record<string, ResolvedDay>
}

function mapRpcDay(row: Record<string, unknown>): PlannerDayRecord {
  return {
    scope: row.scope as PlannerScope,
    employee_id: (row.employee_id as string | null) ?? null,
    site_id: (row.site_id as string | null) ?? null,
    employee_name: (row.employee_name as string | null) ?? null,
    department_id: (row.department_id as string | null) ?? null,
    calendar_group_id: (row.calendar_group_id as string | null) ?? null,
    date: String(row.date).slice(0, 10),
    day_type: row.day_type as TenantDayType,
    day_name: (row.day_name as string | null) ?? null,
    work_intervals: parseWorkIntervals(row.work_intervals),
    planned_minutes: Number(row.planned_minutes ?? 0),
    source: String(row.source ?? 'none'),
  }
}

export function plannerDayToResolved(day: PlannerDayRecord): ResolvedDay {
  return {
    date: day.date,
    type: day.day_type,
    name: day.day_name ?? undefined,
    intervals: day.work_intervals,
    source: day.source as ResolvedDay['source'],
    fromAssignedHoliday: day.source === 'assigned_holiday',
    hasScopeGroupOverride: false,
  }
}

export function buildPlannerGridRows(
  days: PlannerDayRecord[],
  tenantLabel: string,
  siteLabel: string,
): PlannerGridRow[] {
  const byKey = new Map<string, PlannerGridRow>()

  for (const day of days) {
    let key: string
    let label: string

    if (day.scope === 'tenant') {
      key = 'tenant'
      label = tenantLabel
    } else if (day.scope === 'site') {
      key = `site:${day.site_id ?? 'none'}`
      label = siteLabel
    } else {
      key = `emp:${day.employee_id}`
      label = day.employee_name ?? day.employee_id ?? '—'
    }

    let row = byKey.get(key)
    if (!row) {
      row = {
        id: key,
        scope: day.scope,
        label,
        employeeId: day.employee_id ?? undefined,
        departmentId: day.department_id,
        calendarGroupId: day.calendar_group_id,
        days: {},
      }
      byKey.set(key, row)
    }
    row.days[day.date] = plannerDayToResolved(day)
  }

  const order: PlannerScope[] = ['tenant', 'site', 'employee']
  return [...byKey.values()].sort((a, b) => {
    const oa = order.indexOf(a.scope)
    const ob = order.indexOf(b.scope)
    if (oa !== ob) return oa - ob
    return a.label.localeCompare(b.label, 'ca')
  })
}

export async function fetchSchedulePlannerDays(
  siteId: string,
  from: string,
  to: string,
  employeeIds?: string[] | null,
): Promise<PlannerDayRecord[]> {
  const { data, error } = await supabase.rpc('get_schedule_planner_days' as never, {
    p_site_id: siteId,
    p_from: from,
    p_to: to,
    p_employee_ids: employeeIds?.length ? employeeIds : null,
  } as never)
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map(mapRpcDay)
}

export async function fetchSchedulePlannerActuals(
  siteId: string,
  from: string,
  to: string,
  employeeIds?: string[] | null,
): Promise<PlannerActualRecord[]> {
  const { data, error } = await supabase.rpc('get_schedule_planner_actuals' as never, {
    p_site_id: siteId,
    p_from: from,
    p_to: to,
    p_employee_ids: employeeIds?.length ? employeeIds : null,
  } as never)
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((row) => ({
    employee_id: String(row.employee_id),
    work_date: String(row.work_date).slice(0, 10),
    worked_minutes: Number(row.worked_minutes ?? 0),
    punch_count: Number(row.punch_count ?? 0),
    needs_review: Boolean(row.needs_review),
    anomaly_codes: (row.anomaly_codes as string[] | null) ?? null,
    status: (row.status as string | null) ?? null,
  }))
}

export function eachDateInRange(from: string, to: string): string[] {
  const dates: string[] = []
  const cur = new Date(`${from}T12:00:00`)
  const end = new Date(`${to}T12:00:00`)
  while (cur <= end) {
    dates.push(toLocalIsoDate(cur))
    cur.setDate(cur.getDate() + 1)
  }
  return dates
}

/** Calendar date in local timezone (YYYY-MM-DD). Avoids UTC shift from toISOString(). */
export function toLocalIsoDate(d: Date): string {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

export function monthBounds(year: number, month: number): { from: string; to: string } {
  const from = `${year}-${String(month + 1).padStart(2, '0')}-01`
  const last = new Date(year, month + 1, 0).getDate()
  const to = `${year}-${String(month + 1).padStart(2, '0')}-${String(last).padStart(2, '0')}`
  return { from, to }
}

export function weekBounds(anchor: Date, weekStartsOn = 1): { from: string; to: string } {
  const d = new Date(anchor)
  const offset = (d.getDay() - weekStartsOn + 7) % 7
  d.setDate(d.getDate() - offset)
  const from = toLocalIsoDate(d)
  const end = new Date(d)
  end.setDate(end.getDate() + 6)
  return { from, to: toLocalIsoDate(end) }
}

/** Fiscal week number (1-based) for the week containing anchor, per tenant week_starts_on. */
export function fiscalWeekNumber(anchor: Date, weekStartsOn = 1): number {
  const { from } = weekBounds(anchor, weekStartsOn)
  const weekStart = new Date(`${from}T12:00:00`)
  const year = weekStart.getFullYear()

  const jan1 = new Date(`${year}-01-01T12:00:00`)
  const jan1Offset = (jan1.getDay() - weekStartsOn + 7) % 7
  const yearFirstWeek = new Date(jan1)
  yearFirstWeek.setDate(jan1.getDate() - jan1Offset)

  const diffDays = Math.round((weekStart.getTime() - yearFirstWeek.getTime()) / 86_400_000)
  if (diffDays < 0) {
    const prevJan1 = new Date(`${year - 1}-01-01T12:00:00`)
    const prevOffset = (prevJan1.getDay() - weekStartsOn + 7) % 7
    const prevFirst = new Date(prevJan1)
    prevFirst.setDate(prevJan1.getDate() - prevOffset)
    const prevDiff = Math.round((weekStart.getTime() - prevFirst.getTime()) / 86_400_000)
    return Math.floor(prevDiff / 7) + 1
  }
  return Math.floor(diffDays / 7) + 1
}

export function yearBounds(year: number): { from: string; to: string } {
  return { from: `${year}-01-01`, to: `${year}-12-31` }
}

export interface PlannerPeriodBounds {
  from: string
  to: string
  dates: string[]
  year: number
}

export function getPlannerPeriodBounds(
  anchor: Date,
  viewMode: 'month' | 'week' | 'year',
  weekStartsOn = 1,
): PlannerPeriodBounds {
  if (viewMode === 'week') {
    const { from, to } = weekBounds(anchor, weekStartsOn)
    return { from, to, dates: eachDateInRange(from, to), year: anchor.getFullYear() }
  }
  if (viewMode === 'year') {
    const year = anchor.getFullYear()
    const { from, to } = yearBounds(year)
    return { from, to, dates: eachDateInRange(from, to), year }
  }
  const year = anchor.getFullYear()
  const month = anchor.getMonth()
  const { from, to } = monthBounds(year, month)
  return { from, to, dates: eachDateInRange(from, to), year }
}

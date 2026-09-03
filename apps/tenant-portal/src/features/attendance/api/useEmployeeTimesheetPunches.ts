import { useQuery } from '@tanstack/react-query'
import { useMemo } from 'react'
import type { TimePunch } from './attendanceService'
import { punchWorkDate } from './recordRows'
import { eachDateInRange } from './schedulePlannerService'
import { supabase } from '@/lib/supabase'
import { fetchResolveWorkDay, type ResolvedWorkDay } from './workDayResolveService'

export function employeeTimesheetPunchesQueryKey(
  employeeId: string,
  from: string,
  to: string,
) {
  return ['attendance', 'employee-timesheet-punches', employeeId, from, to] as const
}

export async function fetchEmployeePunchesInRange(
  employeeId: string,
  from: string,
  to: string,
): Promise<TimePunch[]> {
  const { data, error } = await supabase
    .from('time_punches')
    .select('id, punch_type, pause_type, occurred_at, anomaly_codes')
    .eq('employee_id', employeeId)
    .gte('occurred_at', `${from}T00:00:00`)
    .lte('occurred_at', `${to}T23:59:59.999`)
    .order('occurred_at', { ascending: true })

  if (error) throw new Error(error.message)

  const dates = new Set(eachDateInRange(from, to))
  return ((data ?? []) as TimePunch[]).filter(
    (p) => p.occurred_at && dates.has(punchWorkDate(p.occurred_at)),
  )
}

async function fetchResolveWorkDaysInRange(
  employeeId: string,
  from: string,
  to: string,
): Promise<Map<string, ResolvedWorkDay>> {
  const dates = eachDateInRange(from, to)
  const resolved = await Promise.all(
    dates.map((date) => fetchResolveWorkDay(employeeId, date)),
  )
  return new Map(dates.map((date, index) => [date, resolved[index]!]))
}

export interface TimesheetDayAdjustment {
  work_date: string
  net_minutes: number | null
  break_minutes: number | null
  adjustment_note: string | null
  starts_at: string | null
  ends_at: string | null
}

export interface EmployeeTimesheetPunchContext {
  punchesByDate: Map<string, TimePunch[]>
  scheduleByDate: Map<string, ResolvedWorkDay>
  adjustmentByDate: Map<string, TimesheetDayAdjustment>
}

async function fetchAdjustedEntriesInRange(
  employeeId: string,
  from: string,
  to: string,
): Promise<Map<string, TimesheetDayAdjustment>> {
  const { data, error } = await supabase
    .from('time_entries')
    .select('work_date, status, net_minutes, break_minutes, adjustment_note, starts_at, ends_at')
    .eq('employee_id', employeeId)
    .eq('status', 'adjusted')
    .gte('work_date', from)
    .lte('work_date', to)

  if (error) throw new Error(error.message)

  const map = new Map<string, TimesheetDayAdjustment>()
  for (const row of data ?? []) {
    const workDate = String(row.work_date).slice(0, 10)
    map.set(workDate, {
      work_date: workDate,
      net_minutes: row.net_minutes,
      break_minutes: row.break_minutes,
      adjustment_note: row.adjustment_note,
      starts_at: row.starts_at,
      ends_at: row.ends_at,
    })
  }
  return map
}

export function useEmployeeTimesheetPunches(
  employeeId: string | null | undefined,
  from: string,
  to: string,
  enabled = true,
) {
  const query = useQuery({
    queryKey: employeeTimesheetPunchesQueryKey(employeeId ?? '', from, to),
    queryFn: async (): Promise<EmployeeTimesheetPunchContext> => {
      const [punches, scheduleByDate, adjustmentByDate] = await Promise.all([
        fetchEmployeePunchesInRange(employeeId!, from, to),
        fetchResolveWorkDaysInRange(employeeId!, from, to),
        fetchAdjustedEntriesInRange(employeeId!, from, to),
      ])

      const punchesByDate = new Map<string, TimePunch[]>()
      for (const punch of punches) {
        if (!punch.occurred_at) continue
        const workDate = punchWorkDate(punch.occurred_at)
        const list = punchesByDate.get(workDate) ?? []
        list.push(punch)
        punchesByDate.set(workDate, list)
      }

      return { punchesByDate, scheduleByDate, adjustmentByDate }
    },
    enabled: enabled && !!employeeId && !!from && !!to,
    staleTime: 60_000,
  })

  const empty = useMemo(
    (): EmployeeTimesheetPunchContext => ({
      punchesByDate: new Map(),
      scheduleByDate: new Map(),
      adjustmentByDate: new Map(),
    }),
    [],
  )

  return {
    ...query,
    punchContext: query.data ?? empty,
  }
}

import type { ResolvedDay } from '../components/LaborCalendarGrid'
import { totalWorkMinutes } from './workIntervals'
import type { PlannerActualRecord, PlannerGridRow } from './schedulePlannerService'

export type PlannerDiscrepancyType = 'missing_punch' | 'unexpected_work' | 'hours_mismatch'

export const DISCREPANCY_TOLERANCE_MINUTES = 15

export type PlannerGroupBy = 'none' | 'department' | 'calendar_group'

export interface PlannerFilters {
  search: string
  departmentId: string | null
  calendarGroupId: string | null
  discrepancyOnly: boolean
  sortBy: 'name' | 'planned_hours'
  groupBy: PlannerGroupBy
}

export const DEFAULT_PLANNER_FILTERS: PlannerFilters = {
  search: '',
  departmentId: null,
  calendarGroupId: null,
  discrepancyOnly: false,
  sortBy: 'name',
  groupBy: 'none',
}

const UNASSIGNED_KEY = '\uffff__none'

export function buildActualsLookup(
  actuals: PlannerActualRecord[],
): Map<string, PlannerActualRecord> {
  const map = new Map<string, PlannerActualRecord>()
  for (const a of actuals) {
    map.set(`${a.employee_id}|${a.work_date}`, a)
  }
  return map
}

export function plannedMinutesForDay(state: ResolvedDay | undefined): number {
  if (!state || state.type !== 'work') return 0
  return totalWorkMinutes(state.intervals)
}

export function detectDiscrepancy(
  planned: ResolvedDay | undefined,
  actual: PlannerActualRecord | undefined,
  toleranceMinutes = DISCREPANCY_TOLERANCE_MINUTES,
  actualsLoaded = false,
): PlannerDiscrepancyType | null {
  if (!actualsLoaded || !planned?.date) return null

  const today = new Date().toISOString().slice(0, 10)
  if (planned.date > today) return null

  const worked = actual?.worked_minutes ?? 0
  const punches = actual?.punch_count ?? 0
  const plannedMin = plannedMinutesForDay(planned)

  if (planned.type === 'work' && punches === 0) return 'missing_punch'
  if ((planned.type === 'holiday' || planned.type === 'vacation') && worked > 0) {
    return 'unexpected_work'
  }
  if (planned.type === 'work' && punches > 0 && Math.abs(worked - plannedMin) > toleranceMinutes) {
    return 'hours_mismatch'
  }
  return null
}

export function rowHasDiscrepancy(
  row: PlannerGridRow,
  dates: string[],
  actuals: Map<string, PlannerActualRecord>,
  actualsLoaded: boolean,
): boolean {
  if (!actualsLoaded || !row.employeeId) return false
  for (const date of dates) {
    const planned = row.days[date]
    const actual = actuals.get(`${row.employeeId}|${date}`)
    if (detectDiscrepancy(planned, actual, DISCREPANCY_TOLERANCE_MINUTES, true)) return true
  }
  return false
}

function totalPlannedMinutes(row: PlannerGridRow, dates: string[]): number {
  return dates.reduce((sum, d) => sum + plannedMinutesForDay(row.days[d]), 0)
}

function groupKeyForRow(row: PlannerGridRow, groupBy: PlannerGroupBy): string {
  if (groupBy === 'department') {
    return row.departmentId ?? UNASSIGNED_KEY
  }
  if (groupBy === 'calendar_group') {
    return row.calendarGroupId ?? UNASSIGNED_KEY
  }
  return ''
}

function groupLabelForKey(
  key: string,
  groupBy: PlannerGroupBy,
  departmentNames: Map<string, string>,
  groupNames: Map<string, string>,
  noneLabel: string,
): string {
  if (key === UNASSIGNED_KEY) return noneLabel
  if (groupBy === 'department') return departmentNames.get(key) ?? key
  if (groupBy === 'calendar_group') return groupNames.get(key) ?? key
  return key
}

function makeGroupHeaderRow(id: string, label: string): PlannerGridRow {
  return {
    id,
    scope: 'group',
    label,
    days: {},
  }
}

function sortEmployees(
  employees: PlannerGridRow[],
  dates: string[],
  sortBy: PlannerFilters['sortBy'],
): PlannerGridRow[] {
  return [...employees].sort((a, b) => {
    if (sortBy === 'planned_hours') {
      return totalPlannedMinutes(b, dates) - totalPlannedMinutes(a, dates)
    }
    return a.label.localeCompare(b.label, 'ca')
  })
}

function orderedGroupKeys(
  groupBy: PlannerGroupBy,
  buckets: Map<string, PlannerGridRow[]>,
  allDepartmentIds: string[],
  allGroupIds: string[],
  departmentNames: Map<string, string>,
  groupNames: Map<string, string>,
  noneLabel: string,
): string[] {
  if (groupBy === 'calendar_group') {
    const keys = allGroupIds.length > 0 ? [...allGroupIds] : [...buckets.keys()]
    if (buckets.has(UNASSIGNED_KEY) && !keys.includes(UNASSIGNED_KEY)) {
      keys.push(UNASSIGNED_KEY)
    }
    for (const key of buckets.keys()) {
      if (!keys.includes(key)) keys.push(key)
    }
    return keys
  }

  if (groupBy === 'department') {
    const keys = allDepartmentIds.length > 0 ? [...allDepartmentIds] : [...buckets.keys()]
    if (buckets.has(UNASSIGNED_KEY) && !keys.includes(UNASSIGNED_KEY)) {
      keys.push(UNASSIGNED_KEY)
    }
    for (const key of buckets.keys()) {
      if (!keys.includes(key)) keys.push(key)
    }
    return keys.sort((a, b) => {
      const la = groupLabelForKey(a, groupBy, departmentNames, groupNames, noneLabel)
      const lb = groupLabelForKey(b, groupBy, departmentNames, groupNames, noneLabel)
      return la.localeCompare(lb, 'ca')
    })
  }

  return [...buckets.keys()].sort((a, b) => {
    const la = groupLabelForKey(a, groupBy, departmentNames, groupNames, noneLabel)
    const lb = groupLabelForKey(b, groupBy, departmentNames, groupNames, noneLabel)
    return la.localeCompare(lb, 'ca')
  })
}

function buildGroupedEmployees(
  employees: PlannerGridRow[],
  groupBy: PlannerGroupBy,
  dates: string[],
  sortBy: PlannerFilters['sortBy'],
  departmentNames: Map<string, string>,
  groupNames: Map<string, string>,
  noneLabel: string,
  allDepartmentIds: string[],
  allGroupIds: string[],
): PlannerGridRow[] {
  const buckets = new Map<string, PlannerGridRow[]>()

  for (const row of employees) {
    const key = groupKeyForRow(row, groupBy)
    const list = buckets.get(key) ?? []
    list.push(row)
    buckets.set(key, list)
  }

  const keys = orderedGroupKeys(
    groupBy,
    buckets,
    allDepartmentIds,
    allGroupIds,
    departmentNames,
    groupNames,
    noneLabel,
  )

  const result: PlannerGridRow[] = []
  for (const key of keys) {
    const groupEmployees = buckets.get(key) ?? []
    const label = groupLabelForKey(key, groupBy, departmentNames, groupNames, noneLabel)
    result.push(makeGroupHeaderRow(`group:${key}`, label))
    result.push(...sortEmployees(groupEmployees, dates, sortBy))
  }

  return result
}

export function applyPlannerFilters(
  rows: PlannerGridRow[],
  dates: string[],
  filters: PlannerFilters,
  actuals: Map<string, PlannerActualRecord>,
  departmentNames: Map<string, string>,
  groupNames: Map<string, string>,
  actualsLoaded = false,
  noneGroupLabel = 'Sense assignar',
  allDepartmentIds: string[] = [],
  allGroupIds: string[] = [],
): PlannerGridRow[] {
  const reference = rows.filter((r) => r.scope !== 'employee')
  let employees = rows.filter((r) => r.scope === 'employee')

  const q = filters.search.trim().toLowerCase()
  if (q) {
    employees = employees.filter((r) => r.label.toLowerCase().includes(q))
  }
  if (filters.departmentId) {
    employees = employees.filter((r) => r.departmentId === filters.departmentId)
  }
  if (filters.calendarGroupId) {
    employees = employees.filter((r) => r.calendarGroupId === filters.calendarGroupId)
  }
  if (filters.discrepancyOnly && actualsLoaded) {
    employees = employees.filter((r) => rowHasDiscrepancy(r, dates, actuals, true))
  }

  if (filters.groupBy === 'none') {
    employees = sortEmployees(employees, dates, filters.sortBy)
  } else {
    employees = buildGroupedEmployees(
      employees,
      filters.groupBy,
      dates,
      filters.sortBy,
      departmentNames,
      groupNames,
      noneGroupLabel,
      allDepartmentIds,
      allGroupIds,
    )
  }

  return [...reference, ...employees]
}

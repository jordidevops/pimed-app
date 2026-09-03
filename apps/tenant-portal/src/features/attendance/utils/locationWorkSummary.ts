import type { TimePunch } from '../api/attendanceService'
import { punchWorkDate } from '../api/recordRows'

export interface LocationWorkSummaryRow {
  employee_id: string
  employee_name: string
  location_id: string | null
  location_name: string
  work_minutes: number
  interval_count: number
  open_interval_count: number
}

type LocationKey = {
  id: string | null
  name: string
}

type Accumulator = {
  employee_id: string
  employee_name: string
  location_id: string | null
  location_name: string
  work_minutes: number
  interval_count: number
  open_interval_count: number
}

type OpenInterval = {
  startedAtMs: number
  location: LocationKey
}

function locationFromPunch(punch: TimePunch): LocationKey {
  const name = punch.location_name_snapshot?.trim()
  return {
    id: punch.location_id ?? null,
    name: name && name.length > 0 ? name : 'Sense ubicació',
  }
}

function accKey(employeeId: string, locationId: string | null): string {
  return `${employeeId}::${locationId ?? ''}`
}

function getOrCreateAcc(
  map: Map<string, Accumulator>,
  employeeId: string,
  employeeName: string,
  location: LocationKey,
): Accumulator {
  const key = accKey(employeeId, location.id)
  const existing = map.get(key)
  if (existing) return existing

  const created: Accumulator = {
    employee_id: employeeId,
    employee_name: employeeName,
    location_id: location.id,
    location_name: location.name,
    work_minutes: 0,
    interval_count: 0,
    open_interval_count: 0,
  }
  map.set(key, created)
  return created
}

function addWorkMinutes(
  map: Map<string, Accumulator>,
  employeeId: string,
  employeeName: string,
  location: LocationKey,
  minutes: number,
) {
  if (minutes <= 0) return
  const acc = getOrCreateAcc(map, employeeId, employeeName, location)
  acc.work_minutes += minutes
  acc.interval_count += 1
}

function closeOpenInterval(
  map: Map<string, Accumulator>,
  employeeId: string,
  employeeName: string,
  open: OpenInterval,
  endMs: number,
) {
  const minutes = Math.round((endMs - open.startedAtMs) / 60_000)
  addWorkMinutes(map, employeeId, employeeName, open.location, minutes)
}

function processEmployeeDayPunches(
  map: Map<string, Accumulator>,
  employeeId: string,
  employeeName: string,
  dayPunches: TimePunch[],
) {
  const sorted = [...dayPunches].sort((a, b) =>
    (a.occurred_at ?? '').localeCompare(b.occurred_at ?? ''),
  )

  let open: OpenInterval | null = null

  for (const punch of sorted) {
    if (!punch.occurred_at) continue
    const punchMs = new Date(punch.occurred_at).getTime()
    const punchLocation = locationFromPunch(punch)
    const type = punch.punch_type

    if (type === 'in' || type === 'day_start') {
      if (open) {
        closeOpenInterval(map, employeeId, employeeName, open, punchMs)
      }
      open = { startedAtMs: punchMs, location: punchLocation }
      continue
    }

    if (type === 'break_start') {
      if (open) {
        closeOpenInterval(map, employeeId, employeeName, open, punchMs)
        open = null
      }
      continue
    }

    if (type === 'break_end') {
      open = { startedAtMs: punchMs, location: punchLocation }
      continue
    }

    if (type === 'out' || type === 'day_end') {
      if (open) {
        closeOpenInterval(map, employeeId, employeeName, open, punchMs)
        open = null
      }
    }
  }

  if (open) {
    const acc = getOrCreateAcc(map, employeeId, employeeName, open.location)
    acc.open_interval_count += 1
  }
}

/**
 * Agrega minuts treballats per empleat i ubicació a partir de parells in/out (i pauses).
 * Només compta intervals tancats; els oberts incrementen open_interval_count.
 */
export function aggregateLocationWorkSummary(
  punches: TimePunch[],
  employeeNames: Record<string, string>,
): LocationWorkSummaryRow[] {
  const byEmployeeDay = new Map<string, TimePunch[]>()

  for (const punch of punches) {
    if (!punch.employee_id || !punch.occurred_at) continue
    const workDate = punchWorkDate(punch.occurred_at)
    const key = `${punch.employee_id}::${workDate}`
    const list = byEmployeeDay.get(key) ?? []
    list.push(punch)
    byEmployeeDay.set(key, list)
  }

  const accMap = new Map<string, Accumulator>()

  for (const [key, dayPunches] of byEmployeeDay) {
    const employeeId = key.split('::')[0]!
    const employeeName = employeeNames[employeeId] ?? employeeId
    processEmployeeDayPunches(accMap, employeeId, employeeName, dayPunches)
  }

  return [...accMap.values()]
    .filter((row) => row.work_minutes > 0 || row.open_interval_count > 0)
    .sort((a, b) => {
      const byEmployee = a.employee_name.localeCompare(b.employee_name, 'ca')
      if (byEmployee !== 0) return byEmployee
      const byLocation = a.location_name.localeCompare(b.location_name, 'ca')
      if (byLocation !== 0) return byLocation
      return b.work_minutes - a.work_minutes
    })
}

function csvEscape(value: string): string {
  if (/[",\n\r]/.test(value)) {
    return `"${value.replace(/"/g, '""')}"`
  }
  return value
}

export function formatLocationWorkHours(minutes: number): string {
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return `${h}:${String(m).padStart(2, '0')}`
}

export function locationWorkSummaryToCsv(
  rows: LocationWorkSummaryRow[],
  headers: {
    employee_name: string
    location_name: string
    work_hours: string
    work_minutes: string
    interval_count: string
    open_interval_count: string
  },
): string {
  const columns = [
    'employee_name',
    'location_name',
    'work_hours',
    'work_minutes',
    'interval_count',
    'open_interval_count',
  ] as const

  const headerLine = columns.map((col) => csvEscape(headers[col])).join(',')
  const dataLines = rows.map((row) =>
    [
      row.employee_name,
      row.location_name,
      formatLocationWorkHours(row.work_minutes),
      String(row.work_minutes),
      String(row.interval_count),
      String(row.open_interval_count),
    ]
      .map((value) => csvEscape(value))
      .join(','),
  )
  return [headerLine, ...dataLines].join('\r\n')
}

export function downloadLocationWorkSummaryCsv(
  rows: LocationWorkSummaryRow[],
  headers: Parameters<typeof locationWorkSummaryToCsv>[1],
  filenameBase: string,
): void {
  const csv = locationWorkSummaryToCsv(rows, headers)
  const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `${filenameBase}.csv`
  a.click()
  URL.revokeObjectURL(url)
}

import { supabase } from '@/lib/supabase'
import type { TimePunch } from './attendanceService'
import { punchWorkDate } from './recordRows'
import { formatPunchSourceLabel } from '../utils/deviceInfo'

export interface PunchExportRow {
  employee_id: string
  employee_name: string
  occurred_at: string
  punch_type: string
  source: string
  location_name: string
  device_name: string
  site_name: string
}

export interface FetchSitePunchesParams {
  siteId: string
  from: string
  to: string
  employeeId?: string
  locationId?: string
  deviceId?: string
}

export async function fetchSitePunchesInRange(
  params: FetchSitePunchesParams,
): Promise<TimePunch[]> {
  let query = supabase
    .from('time_punches')
    .select('*')
    .eq('site_id', params.siteId)
    .gte('occurred_at', `${params.from}T00:00:00`)
    .lte('occurred_at', `${params.to}T23:59:59.999`)
    .order('occurred_at', { ascending: true })

  if (params.employeeId) {
    query = query.eq('employee_id', params.employeeId)
  }
  if (params.locationId) {
    query = query.eq('location_id', params.locationId)
  }
  if (params.deviceId) {
    query = query.eq('device_id', params.deviceId)
  }

  const { data, error } = await query
  if (error) throw new Error(error.message)

  return ((data ?? []) as TimePunch[]).filter((p) => {
    if (!p.occurred_at) return false
    const d = punchWorkDate(p.occurred_at)
    return d >= params.from && d <= params.to
  })
}

function punchTypeLabel(punchType: string | null | undefined): string {
  switch (punchType) {
    case 'in':
      return 'Entrada'
    case 'out':
      return 'Sortida'
    case 'break_start':
      return 'Inici pausa'
    case 'break_end':
      return 'Fi pausa'
    case 'day_start':
      return 'Inici jornada'
    case 'day_end':
      return 'Fi jornada'
    case 'travel_start':
      return 'Inici desplaçament'
    case 'travel_end':
      return 'Fi desplaçament'
    default:
      return punchType ?? ''
  }
}

function csvEscape(value: string): string {
  if (/[",\n\r]/.test(value)) {
    return `"${value.replace(/"/g, '""')}"`
  }
  return value
}

export function buildPunchExportRows(
  punches: TimePunch[],
  employeeNames: Record<string, string>,
  siteName: string,
): PunchExportRow[] {
  return punches.map((p) => ({
    employee_id: p.employee_id ?? '',
    employee_name: employeeNames[p.employee_id ?? ''] ?? p.employee_id ?? '',
    occurred_at: p.occurred_at ?? '',
    punch_type: punchTypeLabel(p.punch_type),
    source: formatPunchSourceLabel(p.source, (_k, fb) => fb) ?? p.source ?? '',
    location_name: p.location_name_snapshot ?? '',
    device_name: p.device_name_snapshot ?? '',
    site_name: siteName,
  }))
}

const PUNCH_EXPORT_COLUMNS: (keyof PunchExportRow)[] = [
  'employee_name',
  'occurred_at',
  'punch_type',
  'source',
  'location_name',
  'device_name',
  'site_name',
]

export function punchesExportToCsv(
  rows: PunchExportRow[],
  headers: Record<keyof PunchExportRow, string>,
): string {
  const headerLine = PUNCH_EXPORT_COLUMNS.map((col) => csvEscape(headers[col])).join(',')
  const dataLines = rows.map((row) =>
    PUNCH_EXPORT_COLUMNS.map((col) => csvEscape(String(row[col] ?? ''))).join(','),
  )
  return [headerLine, ...dataLines].join('\r\n')
}

function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

export function downloadPunchesCsv(
  rows: PunchExportRow[],
  headers: Record<keyof PunchExportRow, string>,
  filenameBase: string,
): void {
  const csv = punchesExportToCsv(rows, headers)
  const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
  triggerDownload(blob, `${filenameBase}.csv`)
}

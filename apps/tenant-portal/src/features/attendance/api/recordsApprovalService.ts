import { supabase } from '@/lib/supabase'

export interface ApproveTimeDayResult {
  summary_id?: string
  status: 'approved' | 'already_approved' | string
}

export interface InspectionExportRow {
  employee_id: string
  employee_name: string
  work_date: string
  starts_at: string | null
  ends_at: string | null
  break_minutes: number | null
  net_minutes: number | null
  gross_minutes: number | null
  expected_minutes: number | null
  worked_minutes: number | null
  overtime_minutes: number | null
  day_type: string | null
  summary_status: string | null
  entry_status: string | null
  anomaly_codes: string[] | null
  punch_count: number | null
  needs_review: boolean
  approved_at: string | null
}

export interface InspectionExportPayload {
  site_id: string
  site_name: string
  from: string
  to: string
  row_count: number
  rows: InspectionExportRow[]
  generated_at: string
}

export async function approveTimeDay(
  employeeId: string,
  workDate: string,
): Promise<ApproveTimeDayResult> {
  const { data, error } = await supabase.rpc('approve_time_day', {
    p_employee_id: employeeId,
    p_work_date: workDate,
  })

  if (error) throw new Error(error.message)
  return data as unknown as ApproveTimeDayResult
}

export async function exportAttendanceInspection(params: {
  siteId: string
  from: string
  to: string
  employeeId?: string
}): Promise<InspectionExportPayload> {
  const { data, error } = await supabase.rpc('export_attendance_inspection', {
    p_site_id: params.siteId,
    p_from: params.from,
    p_to: params.to,
    p_employee_id: params.employeeId,
  })

  if (error) throw new Error(error.message)
  return data as unknown as InspectionExportPayload
}

function formatIsoTime(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleTimeString('ca-ES', { hour: '2-digit', minute: '2-digit' })
}

function minutesToHm(min: number | null | undefined): string {
  if (min == null) return ''
  const h = Math.floor(Math.abs(min) / 60)
  const m = Math.abs(min) % 60
  return `${h}:${String(m).padStart(2, '0')}`
}

export function inspectionExportToCsv(
  payload: InspectionExportPayload,
  headers: Record<string, string>,
): string {
  const cols = [
    'employee_name',
    'work_date',
    'starts_at',
    'ends_at',
    'break_minutes',
    'net_minutes',
    'expected_minutes',
    'worked_minutes',
    'summary_status',
    'anomaly_codes',
    'approved_at',
  ] as const

  const headerLine = cols.map((c) => headers[c] ?? c).join(';')

  const lines = payload.rows.map((row) => {
    const values: string[] = [
      row.employee_name,
      String(row.work_date).slice(0, 10),
      formatIsoTime(row.starts_at),
      formatIsoTime(row.ends_at),
      minutesToHm(row.break_minutes),
      minutesToHm(row.net_minutes),
      minutesToHm(row.expected_minutes),
      minutesToHm(row.worked_minutes),
      row.summary_status ?? '',
      (row.anomaly_codes ?? []).join(', '),
      row.approved_at ? new Date(row.approved_at).toISOString() : '',
    ]
    return values
      .map((v) => `"${String(v).replace(/"/g, '""')}"`)
      .join(';')
  })

  return [headerLine, ...lines].join('\r\n')
}

export function downloadInspectionExport(
  payload: InspectionExportPayload,
  format: 'csv' | 'json',
  csvHeaders?: Record<string, string>,
): void {
  const from = payload.from
  const to = payload.to
  const siteSlug = (payload.site_name || 'site').replace(/\s+/g, '-')

  if (format === 'json') {
    const blob = new Blob([JSON.stringify(payload, null, 2)], {
      type: 'application/json;charset=utf-8',
    })
    triggerDownload(blob, `registre-inspeccio_${siteSlug}_${from}_${to}.json`)
    return
  }

  const csv = inspectionExportToCsv(payload, csvHeaders ?? {})
  const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
  triggerDownload(blob, `registre-inspeccio_${siteSlug}_${from}_${to}.csv`)
}

function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}

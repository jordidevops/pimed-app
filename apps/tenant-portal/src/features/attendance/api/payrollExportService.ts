import { supabase } from '@/lib/supabase'

export type PayrollExportFormat = 'daily' | 'aggregate'

export interface PayrollExportDailyRow {
  employee_id: string
  employee_name: string
  document_id: string | null
  work_date: string
  day_type: string
  expected_minutes: number
  holiday_name: string | null
  is_laborable: boolean
  worked_minutes: number
  overtime_minutes: number
  net_minutes?: number
  presence_minutes?: number | null
  work_minutes?: number | null
  travel_minutes?: number
  effective_minutes?: number | null
  paid_minutes?: number | null
  overtime_authorized_minutes?: number | null
  consolidation_needs_review?: boolean
  work_profile?: string | null
  work_day_type?: string | null
  allowances?: unknown[]
  punch_count: number
  remote_punch_count: number
  entry_status: string | null
  summary_status: string
  needs_review: boolean
  anomaly_codes: string[]
  payroll_locked: boolean
  absence_id: string | null
  absence_type: string | null
  absence_type_name: string | null
  absence_status: string | null
  absence_is_paid: boolean | null
  partial_start_time: string | null
  partial_end_time: string | null
  partial_hours: number | null
  is_it: boolean
  absence_export_code: string | null
  absence_parent_key: string | null
  absence_subtype_key: string | null
  payroll_action: string | null
  compensation_balance_minutes?: number
}

export interface PayrollExportAggregateRow {
  employee_id: string
  employee_name: string
  document_id: string | null
  period_from: string
  period_to: string
  total_expected_minutes: number
  total_worked_minutes: number
  total_overtime_minutes: number
  total_presence_minutes?: number
  total_work_minutes?: number
  total_travel_minutes?: number
  total_effective_minutes?: number
  total_paid_minutes?: number
  total_overtime_authorized_minutes?: number
  laborable_days: number
  worked_days: number
  absence_days: number
  it_days: number
  missing_punch_days: number
  draft_days: number
  approved_days: number
  exported_days: number
  remote_punch_days: number
  compensation_balance_minutes?: number
}

export interface PayrollExportPayload {
  site_id: string
  site_name: string
  from: string
  to: string
  format: PayrollExportFormat
  row_count: number
  rows: PayrollExportDailyRow[] | PayrollExportAggregateRow[]
  generated_at: string
  read_only: boolean
}

function minutesToHm(min: number | null | undefined): string {
  if (min == null) return ''
  const h = Math.floor(Math.abs(min) / 60)
  const m = Math.abs(min) % 60
  return `${h}:${String(m).padStart(2, '0')}`
}

function mapDailyRow(raw: Record<string, unknown>): PayrollExportDailyRow {
  const anomalies = raw.anomaly_codes
  return {
    employee_id: String(raw.employee_id),
    employee_name: String(raw.employee_name ?? ''),
    document_id: (raw.document_id as string | null) ?? null,
    work_date: String(raw.work_date).slice(0, 10),
    day_type: String(raw.day_type ?? ''),
    expected_minutes: Number(raw.expected_minutes ?? 0),
    holiday_name: (raw.holiday_name as string | null) ?? null,
    is_laborable: Boolean(raw.is_laborable),
    worked_minutes: Number(raw.worked_minutes ?? 0),
    net_minutes: raw.net_minutes != null ? Number(raw.net_minutes) : Number(raw.worked_minutes ?? 0),
    presence_minutes: raw.presence_minutes == null ? null : Number(raw.presence_minutes),
    work_minutes: raw.work_minutes == null ? null : Number(raw.work_minutes),
    travel_minutes: Number(raw.travel_minutes ?? 0),
    effective_minutes: raw.effective_minutes == null ? null : Number(raw.effective_minutes),
    paid_minutes: raw.paid_minutes == null ? null : Number(raw.paid_minutes),
    overtime_minutes: Number(raw.overtime_minutes ?? 0),
    overtime_authorized_minutes:
      raw.overtime_authorized_minutes == null ? null : Number(raw.overtime_authorized_minutes),
    consolidation_needs_review: Boolean(raw.consolidation_needs_review ?? raw.needs_review),
    work_profile: (raw.work_profile as string | null) ?? null,
    work_day_type: (raw.work_day_type as string | null) ?? null,
    allowances: Array.isArray(raw.allowances) ? raw.allowances : [],
    punch_count: Number(raw.punch_count ?? 0),
    remote_punch_count: Number(raw.remote_punch_count ?? 0),
    entry_status: (raw.entry_status as string | null) ?? null,
    summary_status: String(raw.summary_status ?? 'none'),
    needs_review: Boolean(raw.needs_review),
    anomaly_codes: Array.isArray(anomalies) ? anomalies.map(String) : [],
    payroll_locked: Boolean(raw.payroll_locked),
    absence_id: (raw.absence_id as string | null) ?? null,
    absence_type: (raw.absence_type as string | null) ?? null,
    absence_type_name: (raw.absence_type_name as string | null) ?? null,
    absence_status: (raw.absence_status as string | null) ?? null,
    absence_is_paid: raw.absence_is_paid == null ? null : Boolean(raw.absence_is_paid),
    partial_start_time: (raw.partial_start_time as string | null) ?? null,
    partial_end_time: (raw.partial_end_time as string | null) ?? null,
    partial_hours: raw.partial_hours == null ? null : Number(raw.partial_hours),
    is_it: Boolean(raw.is_it),
    absence_export_code: (raw.absence_export_code as string | null) ?? null,
    absence_parent_key: (raw.absence_parent_key as string | null) ?? null,
    absence_subtype_key: (raw.absence_subtype_key as string | null) ?? null,
    payroll_action: (raw.payroll_action as string | null) ?? null,
    compensation_balance_minutes:
      raw.compensation_balance_minutes == null
        ? undefined
        : Number(raw.compensation_balance_minutes),
  }
}

function mapAggregateRow(raw: Record<string, unknown>): PayrollExportAggregateRow {
  return {
    employee_id: String(raw.employee_id),
    employee_name: String(raw.employee_name ?? ''),
    document_id: (raw.document_id as string | null) ?? null,
    period_from: String(raw.period_from).slice(0, 10),
    period_to: String(raw.period_to).slice(0, 10),
    total_expected_minutes: Number(raw.total_expected_minutes ?? 0),
    total_worked_minutes: Number(raw.total_worked_minutes ?? 0),
    total_overtime_minutes: Number(raw.total_overtime_minutes ?? 0),
    total_presence_minutes: Number(raw.total_presence_minutes ?? 0),
    total_work_minutes: Number(raw.total_work_minutes ?? 0),
    total_travel_minutes: Number(raw.total_travel_minutes ?? 0),
    total_effective_minutes: Number(raw.total_effective_minutes ?? 0),
    total_paid_minutes: Number(raw.total_paid_minutes ?? 0),
    total_overtime_authorized_minutes: Number(raw.total_overtime_authorized_minutes ?? 0),
    laborable_days: Number(raw.laborable_days ?? 0),
    worked_days: Number(raw.worked_days ?? 0),
    absence_days: Number(raw.absence_days ?? 0),
    it_days: Number(raw.it_days ?? 0),
    missing_punch_days: Number(raw.missing_punch_days ?? 0),
    draft_days: Number(raw.draft_days ?? 0),
    approved_days: Number(raw.approved_days ?? 0),
    exported_days: Number(raw.exported_days ?? 0),
    remote_punch_days: Number(raw.remote_punch_days ?? 0),
    compensation_balance_minutes:
      raw.compensation_balance_minutes == null
        ? undefined
        : Number(raw.compensation_balance_minutes),
  }
}

export async function exportPayrollPeriod(params: {
  siteId: string
  from: string
  to: string
  employeeId?: string
  format?: PayrollExportFormat
}): Promise<PayrollExportPayload> {
  const { data, error } = await supabase.rpc('export_payroll_period' as never, {
    p_site_id: params.siteId,
    p_from: params.from,
    p_to: params.to,
    p_employee_id: params.employeeId ?? null,
    p_format: params.format ?? 'daily',
  } as never)

  if (error) throw new Error(error.message)

  const payload = data as Record<string, unknown>
  const format = (payload.format as PayrollExportFormat) ?? 'daily'
  const rowsRaw = Array.isArray(payload.rows) ? payload.rows : []

  return {
    site_id: String(payload.site_id),
    site_name: String(payload.site_name ?? ''),
    from: String(payload.from).slice(0, 10),
    to: String(payload.to).slice(0, 10),
    format,
    row_count: Number(payload.row_count ?? rowsRaw.length),
    rows:
      format === 'aggregate'
        ? rowsRaw.map((r) => mapAggregateRow(r as Record<string, unknown>))
        : rowsRaw.map((r) => mapDailyRow(r as Record<string, unknown>)),
    generated_at: String(payload.generated_at ?? new Date().toISOString()),
    read_only: Boolean(payload.read_only),
  }
}

export function payrollExportDailyToCsv(
  payload: PayrollExportPayload,
  headers: Record<string, string>,
): string {
  const cols = [
    'employee_name',
    'document_id',
    'work_date',
    'day_type',
    'expected_minutes',
    'worked_minutes',
    'effective_minutes',
    'paid_minutes',
    'travel_minutes',
    'overtime_minutes',
    'is_laborable',
    'holiday_name',
    'punch_count',
    'remote_punch_count',
    'entry_status',
    'summary_status',
    'needs_review',
    'payroll_locked',
    'is_it',
    'absence_type_name',
    'absence_export_code',
    'absence_parent_key',
    'absence_subtype_key',
    'absence_status',
    'absence_is_paid',
    'partial_start_time',
    'partial_end_time',
    'payroll_action',
    'anomaly_codes',
    'compensation_balance_minutes',
  ] as const

  const headerLine = cols.map((c) => headers[c] ?? c).join(';')
  const rows = payload.rows as PayrollExportDailyRow[]

  const lines = rows.map((row) => {
    const values: string[] = [
      row.employee_name,
      row.document_id ?? '',
      row.work_date,
      row.day_type,
      minutesToHm(row.expected_minutes),
      minutesToHm(row.worked_minutes),
      row.effective_minutes != null ? minutesToHm(row.effective_minutes) : '',
      row.paid_minutes != null ? minutesToHm(row.paid_minutes) : '',
      minutesToHm(row.travel_minutes ?? 0),
      minutesToHm(row.overtime_minutes),
      row.is_laborable ? '1' : '0',
      row.holiday_name ?? '',
      String(row.punch_count),
      String(row.remote_punch_count),
      row.entry_status ?? '',
      row.summary_status,
      row.needs_review ? '1' : '0',
      row.payroll_locked ? '1' : '0',
      row.is_it ? '1' : '0',
      row.absence_type_name ?? row.absence_type ?? '',
      row.absence_export_code ?? '',
      row.absence_parent_key ?? '',
      row.absence_subtype_key ?? '',
      row.absence_status ?? '',
      row.absence_is_paid == null ? '' : row.absence_is_paid ? '1' : '0',
      row.partial_start_time?.slice(0, 5) ?? '',
      row.partial_end_time?.slice(0, 5) ?? '',
      row.payroll_action ?? '',
      row.anomaly_codes.join(', '),
      minutesToHm(row.compensation_balance_minutes ?? 0),
    ]
    return values.map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')
  })

  return [headerLine, ...lines].join('\r\n')
}

export function payrollExportAggregateToCsv(
  payload: PayrollExportPayload,
  headers: Record<string, string>,
): string {
  const cols = [
    'employee_name',
    'document_id',
    'period_from',
    'period_to',
    'total_expected_minutes',
    'total_worked_minutes',
    'total_effective_minutes',
    'total_paid_minutes',
    'total_travel_minutes',
    'total_overtime_minutes',
    'laborable_days',
    'worked_days',
    'absence_days',
    'it_days',
    'missing_punch_days',
    'draft_days',
    'approved_days',
    'exported_days',
    'remote_punch_days',
    'compensation_balance_minutes',
  ] as const

  const headerLine = cols.map((c) => headers[c] ?? c).join(';')
  const rows = payload.rows as PayrollExportAggregateRow[]

  const lines = rows.map((row) => {
    const values: string[] = [
      row.employee_name,
      row.document_id ?? '',
      row.period_from,
      row.period_to,
      minutesToHm(row.total_expected_minutes),
      minutesToHm(row.total_worked_minutes),
      minutesToHm(row.total_effective_minutes ?? 0),
      minutesToHm(row.total_paid_minutes ?? 0),
      minutesToHm(row.total_travel_minutes ?? 0),
      minutesToHm(row.total_overtime_minutes),
      String(row.laborable_days),
      String(row.worked_days),
      String(row.absence_days),
      String(row.it_days),
      String(row.missing_punch_days),
      String(row.draft_days),
      String(row.approved_days),
      String(row.exported_days),
      String(row.remote_punch_days),
      minutesToHm(row.compensation_balance_minutes ?? 0),
    ]
    return values.map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')
  })

  return [headerLine, ...lines].join('\r\n')
}

export function downloadPayrollExport(
  payload: PayrollExportPayload,
  format: 'csv' | 'json',
  csvHeaders?: Record<string, string>,
): void {
  const siteSlug = (payload.site_name || 'site').replace(/\s+/g, '-')
  const suffix = payload.format === 'aggregate' ? 'resum' : 'dies'

  if (format === 'json') {
    const blob = new Blob([JSON.stringify(payload, null, 2)], {
      type: 'application/json;charset=utf-8',
    })
    triggerDownload(blob, `export-nomina_${siteSlug}_${suffix}_${payload.from}_${payload.to}.json`)
    return
  }

  const csv =
    payload.format === 'aggregate'
      ? payrollExportAggregateToCsv(payload, csvHeaders ?? {})
      : payrollExportDailyToCsv(payload, csvHeaders ?? {})
  const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
  triggerDownload(blob, `export-nomina_${siteSlug}_${suffix}_${payload.from}_${payload.to}.csv`)
}

function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}

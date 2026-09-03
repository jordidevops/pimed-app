import { supabase } from '@/lib/supabase'
import {
  callSignDocumentRouter,
  extractDocumentIdFromSignResult,
  type SignDocumentResult,
} from '@/features/signing/api/signingService'
import { formatTimesheetMinutes } from './timesheetService'
import { formatDayDetailTime } from './dayDetailService'
import type { MonthlyReportExport } from './monthlyReportService'
import { monthLabel } from './monthlyReportService'
import {
  resolveEmployeeSignerEmail,
  resolveManagerSignerEmail,
  signerEmailRequiredMessage,
} from './signerContactUtils'

export const ATTENDANCE_MONTHLY_REPORT_TEMPLATE_NAME = 'Registre mensual de jornada'

export const ATTENDANCE_MONTHLY_REPORT_TEMPLATE_LOCALE_ID =
  '71000000-0000-0000-0000-000000000029'

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function buildReportBodyHtml(exportData: MonthlyReportExport): string {
  const rows = exportData.days
    .map((day) => {
      const anomalies = (day.anomaly_codes ?? []).join(', ')
      return `<tr>
        <td>${escapeHtml(day.work_date)}</td>
        <td>${escapeHtml(formatDayDetailTime(day.starts_at))}</td>
        <td>${escapeHtml(formatDayDetailTime(day.ends_at))}</td>
        <td>${escapeHtml(formatTimesheetMinutes(day.net_minutes))}</td>
        <td>${escapeHtml(day.status ?? '—')}${anomalies ? ` (${escapeHtml(anomalies)})` : ''}</td>
      </tr>`
    })
    .join('')

  return `<table border="1" cellpadding="4" cellspacing="0" style="width:100%;border-collapse:collapse;font-size:13px;">
    <thead>
      <tr style="background:#f3f4f6;">
        <th>Data</th><th>Entrada</th><th>Sortida</th><th>Net</th><th>Estat</th>
      </tr>
    </thead>
    <tbody>${rows || '<tr><td colspan="5">Cap dia registrat</td></tr>'}</tbody>
  </table>`
}

export async function sha256HexFromJson(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(JSON.stringify(value)),
  )
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export function buildMonthlyReportSigningContext(
  exportData: MonthlyReportExport,
  contentHash: string,
): Record<string, string> {
  const diff = exportData.summary.difference_minutes
  const diffPrefix = diff > 0 ? '+' : ''
  return {
    employee_name: exportData.employee_name,
    period_label: monthLabel(exportData.year, exportData.month),
    worked_hours: formatTimesheetMinutes(exportData.summary.worked_minutes),
    expected_hours: formatTimesheetMinutes(exportData.summary.expected_minutes),
    difference_hours: `${diffPrefix}${formatTimesheetMinutes(diff)}`,
    report_body: buildReportBodyHtml(exportData),
    content_hash: contentHash,
  }
}

export async function linkAttendanceMonthlyReportSigning(params: {
  employeeId: string
  year: number
  month: number
  documentId: string
  signingSubmissionId: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('link_attendance_monthly_report_signing', {
    p_employee_id: params.employeeId,
    p_year: params.year,
    p_month: params.month,
    p_document_id: params.documentId,
    p_signing_submission_id: params.signingSubmissionId,
  })
  if (error) throw new Error(error.message)
  return String(data)
}

export async function startMonthlyReportSigning(params: {
  tenantId: string
  employeeId: string
  userId: string
  year: number
  month: number
  exportData: MonthlyReportExport
  contentHash?: string | null
  templateLocaleId?: string
  employeeEmail?: string | null
  managerEmail?: string | null
  managerName?: string | null
}): Promise<SignDocumentResult> {
  const contentHash =
    params.contentHash ?? (await sha256HexFromJson(params.exportData))

  const employeeEmail = await resolveEmployeeSignerEmail(
    params.employeeId,
    params.employeeEmail,
  )
  if (!employeeEmail) {
    throw new Error(signerEmailRequiredMessage('monthly_report'))
  }

  const managerEmail = resolveManagerSignerEmail(params.managerEmail)
  if (!managerEmail) {
    throw new Error('El responsable necessita un correu electrònic per iniciar la signatura.')
  }

  const managerName =
    params.managerName?.trim() ||
    managerEmail.split('@')[0] ||
    'Responsable'

  const title = `Registre mensual — ${params.exportData.employee_name} — ${monthLabel(params.year, params.month)}`

  const result = await callSignDocumentRouter({
    tenant_id: params.tenantId,
    action: 'sign',
    source_type: 'template_locale',
    source_template_locale_id:
      params.templateLocaleId ?? ATTENDANCE_MONTHLY_REPORT_TEMPLATE_LOCALE_ID,
    document_title: title,
    document_category: 'attendance',
    context: buildMonthlyReportSigningContext(params.exportData, contentHash),
    context_refs: {
      Empleat: { entity_type: 'employee', entity_id: params.employeeId },
      Responsable: { entity_type: 'user', entity_id: params.userId },
    },
    signers: [
      {
        email: employeeEmail,
        name: params.exportData.employee_name,
        role: 'Empleat',
        order: 0,
      },
      {
        email: managerEmail,
        name: managerName,
        role: 'Responsable',
        order: 1,
      },
    ],
    notification_mode: 'app_auto_sequential',
    output_format: 'pdf',
    client_request_id: `attendance-monthly:${params.employeeId}:${params.year}-${params.month}`,
  })

  const documentId = extractDocumentIdFromSignResult(result)
  const submissionId = result.submission_id

  if (documentId && submissionId) {
    await linkAttendanceMonthlyReportSigning({
      employeeId: params.employeeId,
      year: params.year,
      month: params.month,
      documentId,
      signingSubmissionId: submissionId,
    })
  }

  return result
}

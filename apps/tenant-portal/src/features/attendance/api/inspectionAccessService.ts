import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'

export type InspectionLinkStatus = 'active' | 'expired' | 'revoked'

export interface InspectionAccessLink {
  id: string
  employee_id: string
  employee_name: string
  period_from: string
  period_to: string
  expires_at: string
  revoked_at: string | null
  created_at: string
  created_by: string | null
  last_accessed_at: string | null
  first_accessed_at: string | null
  first_access_ip: string | null
  first_access_user_agent: string | null
  last_access_ip: string | null
  last_access_user_agent: string | null
  access_count: number
  label: string | null
  include_consolidated: boolean
  is_active: boolean
  status: InspectionLinkStatus
}

export interface CreateInspectionLinkInput {
  employeeId: string
  periodFrom: string
  periodTo: string
  ttlDays?: number
  label?: string | null
  includeConsolidated?: boolean
}

export interface CreateInspectionLinkResult {
  id: string
  urlSecret: string
  expiresAt: string
  employeeId: string
  employeeName: string
  periodFrom: string
  periodTo: string
  ttlDays: number
  includeConsolidated: boolean
}

export interface InspectionEmployeeOption {
  id: string
  full_name: string
}

export const INSPECTION_MAX_RANGE_DAYS = 400
export const INSPECTION_DEFAULT_TTL_DAYS = 7
export const INSPECTION_MAX_TTL_DAYS = 30

export function buildInspectionUrl(id: string, secret: string): string {
  // Must match the public-portal origin (e.g. http://localhost:3002).
  const base =
    (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined)?.replace(/\/$/, '') ||
    'http://localhost:3000'
  return `${base}/inspect/${id}?t=${encodeURIComponent(secret)}`
}

export function inspectionRangeDays(from: string, to: string): number {
  const f = new Date(`${from}T00:00:00Z`).getTime()
  const tt = new Date(`${to}T00:00:00Z`).getTime()
  if (Number.isNaN(f) || Number.isNaN(tt)) return NaN
  return Math.round((tt - f) / (1000 * 60 * 60 * 24))
}

/** Compact browser hint from a User-Agent string. */
export function summarizeUserAgent(ua: string | null | undefined): string {
  if (!ua) return '—'
  const browsers: Array<[RegExp, string]> = [
    [/Edg\/[\d.]+/i, 'Edge'],
    [/Chrome\/[\d.]+/i, 'Chrome'],
    [/Firefox\/[\d.]+/i, 'Firefox'],
    [/Safari\/[\d.]+/i, 'Safari'],
    [/OPR\/[\d.]+/i, 'Opera'],
  ]
  let browser = 'Navegador'
  for (const [re, name] of browsers) {
    if (re.test(ua)) {
      browser = name
      break
    }
  }
  let os = ''
  if (/Windows/i.test(ua)) os = 'Windows'
  else if (/Android/i.test(ua)) os = 'Android'
  else if (/iPhone|iPad|iOS/i.test(ua)) os = 'iOS'
  else if (/Mac OS X|Macintosh/i.test(ua)) os = 'macOS'
  else if (/Linux/i.test(ua)) os = 'Linux'
  return os ? `${browser} · ${os}` : browser
}

export async function listActiveEmployees(): Promise<InspectionEmployeeOption[]> {
  const { data, error } = await supabase
    .from('employees')
    .select('id, full_name, status')
    .eq('status', 'active')
    .order('full_name', { ascending: true })
  if (error) throw error
  return ((data as InspectionEmployeeOption[] | null) ?? []).map((e) => ({
    id: e.id,
    full_name: e.full_name,
  }))
}

export async function listInspectionAccessLinks(
  includeInactive = false,
): Promise<InspectionAccessLink[]> {
  const { data, error } = await supabase.rpc('list_attendance_inspection_access_links', {
    p_include_inactive: includeInactive,
  })
  if (error) throw error
  return ((data as { links?: InspectionAccessLink[] } | null)?.links) ?? []
}

export async function createInspectionAccessLink(
  input: CreateInspectionLinkInput,
): Promise<CreateInspectionLinkResult> {
  const { data, error } = await supabase.rpc('create_attendance_inspection_access_link', {
    p_employee_id: input.employeeId,
    p_period_from: input.periodFrom,
    p_period_to: input.periodTo,
    p_ttl_days: input.ttlDays ?? INSPECTION_DEFAULT_TTL_DAYS,
    p_label: input.label?.trim() || undefined,
    p_include_consolidated: input.includeConsolidated ?? true,
  })
  if (error) throw error

  const payload = data as {
    id?: string
    url_secret?: string
    expires_at?: string
    employee_id?: string
    employee_name?: string
    period_from?: string
    period_to?: string
    ttl_days?: number
    include_consolidated?: boolean
  } | null

  if (!payload?.id || !payload.url_secret) {
    throw new Error('missing_inspection_link_payload')
  }

  return {
    id: payload.id,
    urlSecret: payload.url_secret,
    expiresAt: payload.expires_at ?? '',
    employeeId: payload.employee_id ?? input.employeeId,
    employeeName: payload.employee_name ?? '',
    periodFrom: payload.period_from ?? input.periodFrom,
    periodTo: payload.period_to ?? input.periodTo,
    ttlDays: payload.ttl_days ?? input.ttlDays ?? INSPECTION_DEFAULT_TTL_DAYS,
    includeConsolidated: payload.include_consolidated ?? input.includeConsolidated ?? true,
  }
}

export async function revokeInspectionAccessLink(linkId: string): Promise<void> {
  const { error } = await supabase.rpc('revoke_attendance_inspection_access_link', {
    p_link_id: linkId,
  })
  if (error) throw error
}

export interface SendInspectionAccessEmailInput {
  tenantId: string
  linkId: string
  secret: string
  recipients: string[]
  locale?: string
}

export interface SendInspectionAccessEmailResult {
  emailLogId: string
  inspectionUrl: string
}

export async function sendInspectionAccessEmail(
  input: SendInspectionAccessEmailInput,
): Promise<SendInspectionAccessEmailResult> {
  const { data, error } = await supabase.functions.invoke(
    'send-attendance-inspection-access-email',
    {
      headers: { 'x-tenant-id': input.tenantId },
      body: {
        link_id: input.linkId,
        secret: input.secret,
        recipients: input.recipients,
        locale: input.locale ?? 'ca',
      },
    },
  )

  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }

  const responseError = getResponseErrorMessage(data)
  if (responseError) throw new Error(responseError)

  const payload = data as { email_log_id?: string; inspection_url?: string }
  if (!payload.email_log_id) throw new Error('missing_email_log_id')

  return {
    emailLogId: payload.email_log_id,
    inspectionUrl: payload.inspection_url ?? '',
  }
}

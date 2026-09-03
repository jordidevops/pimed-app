import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type EmploymentContract = Database['api']['Views']['employment_contracts']['Row']
export type EmploymentContractType = Database['api']['Views']['employment_contract_types']['Row']
export type EmploymentContractInsert = Database['api']['Views']['employment_contracts']['Insert']
export type EmploymentContractUpdate = Database['api']['Views']['employment_contracts']['Update']

export type ContractLifecycleStatus =
  | 'draft'
  | 'scheduled'
  | 'active'
  | 'ended'
  | 'cancelled'

export async function listEmploymentContracts(employeeId: string): Promise<EmploymentContract[]> {
  const { data, error } = await supabase
    .from('employment_contracts')
    .select('*')
    .eq('employee_id', employeeId)
    .order('starts_on', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function listEmploymentContractTypes(activeOnly = true): Promise<EmploymentContractType[]> {
  let q = supabase.from('employment_contract_types').select('*').order('name')
  if (activeOnly) q = q.eq('is_active', true)
  const { data, error } = await q
  if (error) throw error
  return data ?? []
}

export async function getEffectiveEmploymentContract(
  employeeId: string,
  on?: string,
): Promise<EmploymentContract | null> {
  const { data, error } = await supabase.rpc('get_effective_employment_contract', {
    p_employee_id: employeeId,
    p_on: on ?? undefined,
  })
  if (error) throw error
  return data ?? null
}

export async function createEmploymentContract(
  row: EmploymentContractInsert,
): Promise<EmploymentContract> {
  const { data, error } = await supabase
    .from('employment_contracts')
    .insert({
      ...row,
      lifecycle_status: row.lifecycle_status ?? 'draft',
      signature_requirement: row.signature_requirement ?? 'none',
      signature_status: row.signature_status ?? 'not_required',
      is_primary: row.is_primary ?? true,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateEmploymentContract(
  id: string,
  patch: EmploymentContractUpdate,
): Promise<EmploymentContract> {
  const { data, error } = await supabase
    .from('employment_contracts')
    .update(patch)
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function transitionEmploymentContract(
  contractId: string,
  toStatus: ContractLifecycleStatus,
  reason?: string | null,
): Promise<EmploymentContract> {
  const { data, error } = await supabase.rpc('transition_employment_contract', {
    p_contract_id: contractId,
    p_to_status: toStatus,
    p_reason: reason ?? undefined,
  })
  if (error) throw error
  return data
}

export async function reconcileEmploymentContracts(
  employeeId?: string | null,
  on?: string,
): Promise<number> {
  const { data, error } = await supabase.rpc('reconcile_employment_contracts', {
    p_employee_id: employeeId ?? undefined,
    p_on: on ?? undefined,
  })
  if (error) throw error
  return data ?? 0
}

export type EmploymentContractAlert = {
  kind: string
  contract_id: string
  employee_id: string
  full_name?: string | null
  starts_on?: string | null
  ends_on?: string | null
  days_left?: number | null
  days_until?: number | null
  reason?: string | null
  signature_status?: string | null
  is_notice_day?: boolean | null
}

export type EmploymentContractAlertsReport = {
  as_of: string
  tenant_id: string
  count: number
  alerts: EmploymentContractAlert[]
}

export async function listEmploymentContractAlerts(
  employeeId?: string | null,
  on?: string,
): Promise<EmploymentContractAlertsReport> {
  const { data, error } = await supabase.rpc('list_employment_contract_alerts', {
    p_employee_id: employeeId ?? undefined,
    p_as_of: on ?? undefined,
  })
  if (error) throw error
  const rep = (data ?? {}) as EmploymentContractAlertsReport
  return {
    as_of: rep.as_of,
    tenant_id: rep.tenant_id,
    count: rep.count ?? 0,
    alerts: Array.isArray(rep.alerts) ? rep.alerts : [],
  }
}

export async function createEmploymentContractRenewal(
  contractId: string,
  startsOn?: string | null,
  endsOn?: string | null,
): Promise<EmploymentContract> {
  const { data, error } = await supabase.rpc('create_employment_contract_renewal', {
    p_contract_id: contractId,
    p_starts_on: startsOn ?? undefined,
    p_ends_on: endsOn ?? undefined,
  })
  if (error) throw error
  return data
}

/** Platform HTML locale: «Contracte de treball indefinit» (ca) */
export const DEFAULT_EMPLOYMENT_CONTRACT_TEMPLATE_LOCALE_ID =
  '71000000-0000-0000-0000-000000000001'

export async function generateEmploymentContractDocument(params: {
  contractId: string
  templateLocaleId?: string | null
  force?: boolean
}): Promise<EmploymentContract> {
  const { data, error } = await supabase.rpc('generate_employment_contract_document', {
    p_contract_id: params.contractId,
    p_template_locale_id: params.templateLocaleId ?? undefined,
    p_force: params.force ?? false,
  })
  if (error) throw error
  return data
}

export type EmployeeContractTerms = {
  contract_id: string | null
  weekly_hours: number | null
  fte: number | null
  calendar_group_id: string | null
  site_id: string | null
  department_id: string | null
  job_position_id: string | null
  work_entry_source: string | null
  starts_on: string | null
  ends_on: string | null
  source: 'employment_contract' | 'employee_fallback' | string
}

export async function resolveEmployeeContractTerms(
  employeeId: string,
  workDate?: string,
): Promise<EmployeeContractTerms> {
  const { data, error } = await supabase.rpc('resolve_employee_contract_terms', {
    p_employee_id: employeeId,
    p_work_date: workDate ?? undefined,
  })
  if (error) throw error
  const raw = (data ?? {}) as Record<string, unknown>
  return {
    contract_id: raw.contract_id ? String(raw.contract_id) : null,
    weekly_hours: raw.weekly_hours != null ? Number(raw.weekly_hours) : null,
    fte: raw.fte != null ? Number(raw.fte) : null,
    calendar_group_id: raw.calendar_group_id ? String(raw.calendar_group_id) : null,
    site_id: raw.site_id ? String(raw.site_id) : null,
    department_id: raw.department_id ? String(raw.department_id) : null,
    job_position_id: raw.job_position_id ? String(raw.job_position_id) : null,
    work_entry_source: raw.work_entry_source ? String(raw.work_entry_source) : null,
    starts_on: raw.starts_on ? String(raw.starts_on) : null,
    ends_on: raw.ends_on ? String(raw.ends_on) : null,
    source: String(raw.source ?? 'employee_fallback'),
  }
}

export async function resolveEmployeeWorkContext(
  employeeId: string,
  workDate?: string,
): Promise<Record<string, unknown> | null> {
  const { data, error } = await supabase.rpc('resolve_employee_work_context', {
    p_employee_id: employeeId,
    p_work_date: workDate ?? undefined,
    p_requested_site_id: undefined,
  })
  if (error) throw error
  return (data as Record<string, unknown> | null) ?? null
}

export async function linkEmploymentContractDocument(params: {
  contractId: string
  documentId: string
  templateLocaleId?: string | null
  variablesSnapshot?: Record<string, unknown> | null
  templateSnapshot?: Record<string, unknown> | null
}): Promise<EmploymentContract> {
  const { data, error } = await supabase.rpc('link_employment_contract_document', {
    p_contract_id: params.contractId,
    p_document_id: params.documentId,
    p_template_locale_id: params.templateLocaleId ?? undefined,
    p_variables_snapshot: params.variablesSnapshot ?? undefined,
    p_template_snapshot: params.templateSnapshot ?? undefined,
  })
  if (error) throw error
  return data
}

export function isOverlapError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err ?? '')
  return (
    /exclusion|overlap|23P01|employment_contracts_no_primary_overlap/i.test(msg) ||
    /conflicting key value violates exclusion/i.test(msg)
  )
}

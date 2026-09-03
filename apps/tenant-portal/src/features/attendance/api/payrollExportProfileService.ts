import { supabase } from '@/lib/supabase'
import {
  EXAMPLE_A3_AGGREGATE_PROFILE,
  EXAMPLE_SAGE_AGGREGATE_PROFILE,
  type PayrollExportProfile,
  type PayrollExportProfileMapping,
} from './payrollConnectorTypes'
import type { PayrollExportPayload } from './payrollExportService'
import {
  profileMappingFromDbRow,
  profileMappingToDbPayload,
} from './payrollProfileExport'

interface PayrollExportProfileRow {
  id: string
  tenant_id: string
  name: string
  connector: string
  output_format: string
  source_mode: string
  column_mapping: unknown
  concept_mapping: unknown
  header_row: number
  is_active: boolean
  created_at: string
  updated_at: string
}

function rowToProfile(row: PayrollExportProfileRow): PayrollExportProfile {
  return {
    id: row.id,
    tenant_id: row.tenant_id,
    name: row.name,
    connector: row.connector as PayrollExportProfile['connector'],
    source_mode: row.source_mode as PayrollExportProfile['source_mode'],
    output_format: row.output_format as PayrollExportProfile['output_format'],
    is_active: row.is_active,
    mapping: profileMappingFromDbRow(row),
  }
}

export async function listPayrollExportProfiles(tenantId: string): Promise<PayrollExportProfile[]> {
  const { data, error } = await supabase
    .from('payroll_export_profiles' as never)
    .select('*')
    .eq('tenant_id', tenantId)
    .order('name')

  if (error) throw new Error(error.message)
  return ((data ?? []) as PayrollExportProfileRow[]).map(rowToProfile)
}

export async function upsertPayrollExportProfile(input: {
  id?: string
  tenantId: string
  name: string
  connector: PayrollExportProfile['connector']
  source_mode: PayrollExportProfile['source_mode']
  output_format: PayrollExportProfile['output_format']
  mapping: PayrollExportProfileMapping
  is_active?: boolean
}): Promise<PayrollExportProfile> {
  const dbPayload = profileMappingToDbPayload(input.mapping)
  const row = {
    ...(input.id ? { id: input.id } : {}),
    tenant_id: input.tenantId,
    name: input.name,
    connector: input.connector,
    source_mode: input.source_mode,
    output_format: input.output_format,
    column_mapping: dbPayload.column_mapping,
    concept_mapping: dbPayload.concept_mapping,
    header_row: dbPayload.header_row,
    is_active: input.is_active ?? true,
  }

  const { data, error } = await supabase
    .from('payroll_export_profiles' as never)
    .upsert(row as never)
    .select('*')
    .single()

  if (error) throw new Error(error.message)
  return rowToProfile(data as PayrollExportProfileRow)
}

export async function deletePayrollExportProfile(id: string): Promise<void> {
  const { error } = await supabase.from('payroll_export_profiles' as never).delete().eq('id', id)
  if (error) throw new Error(error.message)
}

export async function createPayrollExportProfileFromTemplate(
  tenantId: string,
  template: 'a3' | 'sage',
): Promise<PayrollExportProfile> {
  const base = template === 'a3' ? EXAMPLE_A3_AGGREGATE_PROFILE : EXAMPLE_SAGE_AGGREGATE_PROFILE
  return upsertPayrollExportProfile({
    tenantId,
    name: base.name,
    connector: base.connector,
    source_mode: base.source_mode,
    output_format: base.output_format,
    mapping: base.mapping,
    is_active: true,
  })
}

function mapExportPayload(raw: Record<string, unknown>): PayrollExportPayload {
  const format = (raw.format as PayrollExportPayload['format']) ?? 'daily'
  const rowsRaw = Array.isArray(raw.rows) ? raw.rows : []
  return {
    site_id: String(raw.site_id),
    site_name: String(raw.site_name ?? ''),
    from: String(raw.from).slice(0, 10),
    to: String(raw.to).slice(0, 10),
    format,
    row_count: Number(raw.row_count ?? rowsRaw.length),
    rows: rowsRaw as PayrollExportPayload['rows'],
    generated_at: String(raw.generated_at ?? new Date().toISOString()),
    read_only: Boolean(raw.read_only),
  }
}

export async function exportPayrollWithProfile(params: {
  siteId: string
  from: string
  to: string
  profileId: string
  employeeId?: string
}): Promise<{ profile: PayrollExportProfile; export: PayrollExportPayload }> {
  const { data, error } = await supabase.rpc('export_payroll_period_profile' as never, {
    p_site_id: params.siteId,
    p_from: params.from,
    p_to: params.to,
    p_profile_id: params.profileId,
    p_employee_id: params.employeeId ?? null,
  } as never)

  if (error) throw new Error(error.message)

  const payload = data as { profile: PayrollExportProfileRow; export: Record<string, unknown> }
  return {
    profile: rowToProfile(payload.profile),
    export: mapExportPayload(payload.export),
  }
}

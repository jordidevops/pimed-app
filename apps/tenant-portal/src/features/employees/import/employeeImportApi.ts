import { supabase } from '@/lib/supabase'
import type {
  EmployeeImportRecord,
  ImportEmployeesBulkResult,
  ImportEmployeesOptions,
} from './employeeImportTypes'

export async function importEmployeesBulk(
  rows: EmployeeImportRecord[],
  options: ImportEmployeesOptions = {},
): Promise<ImportEmployeesBulkResult> {
  const { data, error } = await supabase.rpc('import_employees_bulk' as never, {
    p_rows: rows,
    p_options: {
      dry_run: options.dry_run ?? false,
      default_site_id: options.default_site_id ?? null,
      default_provider: options.default_provider ?? 'csv',
      update_mode: options.update_mode ?? 'overwrite',
      force_email_match: options.force_email_match ?? false,
    },
  } as never)

  if (error) throw error
  return data as ImportEmployeesBulkResult
}

export type ExternalEntityMapping = {
  id: string
  tenant_id: string
  provider: string
  entity_type: string
  internal_id: string
  external_id: string
  external_meta: Record<string, unknown> | null
  last_synced_at: string | null
  created_at: string
  updated_at: string
}

export async function listEmployeeExternalMappings(
  employeeId: string,
): Promise<ExternalEntityMapping[]> {
  const { data, error } = await supabase
    .from('external_entity_mappings' as never)
    .select('*')
    .eq('internal_id', employeeId)
    .eq('entity_type', 'employee')
    .order('provider', { ascending: true })

  if (error) throw error
  return (data ?? []) as ExternalEntityMapping[]
}

import { supabase } from '@/lib/supabase'
import type { Database, Json } from '@/types/database.types'

export type ProjectLineFinancials =
  Database['api']['Views']['project_line_financials']['Row']

export async function getProjectLineFinancials(
  lineId: string,
): Promise<ProjectLineFinancials | null> {
  const { data, error } = await supabase
    .from('project_line_financials')
    .select('project_line_id, tenant_id, unit_cost_cents, updated_at')
    .eq('project_line_id', lineId)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function listProjectLineFinancials(
  lineIds: string[],
): Promise<ProjectLineFinancials[]> {
  if (lineIds.length === 0) return []
  const { data, error } = await supabase
    .from('project_line_financials')
    .select('project_line_id, tenant_id, unit_cost_cents, updated_at')
    .in('project_line_id', lineIds)
  if (error) throw error
  return data ?? []
}

export async function setProjectLineFinancials(
  lineId: string,
  patch: { unit_cost_cents?: number | null },
): Promise<void> {
  const body: Record<string, number | null> = {}
  if ('unit_cost_cents' in patch) body.unit_cost_cents = patch.unit_cost_cents ?? null
  const { error } = await supabase.rpc('set_project_line_financials', {
    p_line_id: lineId,
    p_patch: body as Json,
  })
  if (error) throw error
}

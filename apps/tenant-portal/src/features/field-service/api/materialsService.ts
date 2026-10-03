import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { getFieldProjectSnapshot, patchFieldProjectSnapshot } from '@/lib/today-cache'

export type ProjectMaterial = Database['api']['Views']['project_materials']['Row']

export interface AddProjectMaterialInput {
  project_id: string
  name: string
  quantity: number
  unit?: string | null
  work_log_id?: string | null
  work_log_client_op_id?: string | null
  client_op_id?: string
}

export async function getProjectMaterials(
  projectId: string,
  tenantId?: string,
): Promise<ProjectMaterial[]> {
  const { data, error } = await supabase
    .from('project_materials')
    .select('*')
    .eq('project_id', projectId)
    .order('created_at', { ascending: false })
    .limit(100)

  if (error) {
    if (tenantId) {
      const snapshot = await getFieldProjectSnapshot(tenantId, projectId)
      if (snapshot?.materials) return snapshot.materials as ProjectMaterial[]
    }
    throw error
  }
  const materials = data ?? []
  if (tenantId) {
    await patchFieldProjectSnapshot(tenantId, projectId, { materials })
  }
  return materials
}

export async function listMaterialCosts(
  materialIds: string[],
): Promise<{ material_id: string; unit_cost_cents: number }[]> {
  if (materialIds.length === 0) return []
  const { data, error } = await supabase
    .from('project_material_costs' as never)
    .select('material_id, unit_cost_cents')
    .in('material_id', materialIds)
  if (error) throw error
  return (data ?? []) as { material_id: string; unit_cost_cents: number }[]
}

export async function setProjectMaterialAmounts(
  materialId: string,
  patch: { unit_price_cents?: number | null; unit_cost_cents?: number | null },
): Promise<void> {
  const { error } = await supabase.rpc('set_project_material_amounts' as never, {
    p_material_id: materialId,
    p_patch: patch,
  } as never)
  if (error) throw error
}

export async function addProjectMaterial(input: AddProjectMaterialInput): Promise<void> {
  const { error } = await supabase.rpc('add_project_material' as never, {
    p_project_id: input.project_id,
    p_name: input.name,
    p_quantity: input.quantity,
    p_unit: input.unit ?? null,
    p_work_log_id: input.work_log_id ?? null,
    p_work_log_client_op_id: input.work_log_client_op_id ?? null,
    p_client_op_id: input.client_op_id ?? generateClientOpId(),
  } as never)

  if (error) throw error
}

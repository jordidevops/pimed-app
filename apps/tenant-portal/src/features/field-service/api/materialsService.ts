import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type ProjectMaterial = Database['api']['Views']['project_materials']['Row']

export interface AddProjectMaterialInput {
  tenant_id: string
  project_id: string
  name: string
  quantity: number
  unit?: string | null
  work_log_id?: string | null
}

export async function getProjectMaterials(projectId: string): Promise<ProjectMaterial[]> {
  const { data, error } = await supabase
    .from('project_materials')
    .select('*')
    .eq('project_id', projectId)
    .order('created_at', { ascending: false })
    .limit(100)

  if (error) throw error
  return data ?? []
}

export async function addProjectMaterial(input: AddProjectMaterialInput): Promise<void> {
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser()
  if (userError) throw userError
  if (!user?.id) throw new Error('unauthenticated')

  const { error } = await supabase.from('project_materials').insert({
    tenant_id: input.tenant_id,
    project_id: input.project_id,
    name: input.name,
    quantity: input.quantity,
    unit: input.unit ?? null,
    work_log_id: input.work_log_id ?? null,
    created_by: user.id,
  })

  if (error) throw error
}

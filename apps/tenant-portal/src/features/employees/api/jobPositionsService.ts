import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type JobPosition = Database['api']['Views']['job_positions']['Row']
export type JobPositionInsert = Database['api']['Views']['job_positions']['Insert']
export type JobPositionUpdate = Database['api']['Views']['job_positions']['Update']

export async function getJobPositions(activeOnly = false): Promise<JobPosition[]> {
  let query = supabase.from('job_positions').select('*').order('name', { ascending: true })
  if (activeOnly) query = query.eq('is_active', true)
  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export async function createJobPosition(
  params: Pick<JobPositionInsert, 'tenant_id' | 'name' | 'code' | 'description' | 'department_id' | 'is_active'>,
): Promise<JobPosition> {
  const { data, error } = await supabase.from('job_positions').insert(params).select().single()
  if (error) throw error
  return data
}

export async function updateJobPosition(id: string, params: JobPositionUpdate): Promise<JobPosition> {
  const { data, error } = await supabase.from('job_positions').update(params).eq('id', id).select().single()
  if (error) throw error
  return data
}

export async function deleteJobPosition(id: string): Promise<void> {
  const { error } = await supabase.from('job_positions').delete().eq('id', id)
  if (error) throw error
}

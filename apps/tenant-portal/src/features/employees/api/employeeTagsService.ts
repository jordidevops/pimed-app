import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type EmployeeTag = Database['api']['Views']['employee_tags']['Row']
export type EmployeeTagAssignment = Database['api']['Views']['employee_tag_assignments']['Row']

export async function getEmployeeTags(activeOnly = true): Promise<EmployeeTag[]> {
  let query = supabase.from('employee_tags').select('*').order('name', { ascending: true })
  if (activeOnly) query = query.eq('is_active', true)
  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export async function getEmployeeTagAssignments(employeeId: string): Promise<EmployeeTagAssignment[]> {
  const { data, error } = await supabase
    .from('employee_tag_assignments')
    .select('*')
    .eq('employee_id', employeeId)
  if (error) throw error
  return data ?? []
}

export async function ensureEmployeeTag(name: string, colorToken?: string | null): Promise<EmployeeTag> {
  const { data, error } = await supabase.rpc('ensure_employee_tag', {
    p_name: name,
    p_color_token: colorToken ?? null,
  })
  if (error) throw error
  return data as EmployeeTag
}

export async function setEmployeeTags(employeeId: string, tagIds: string[]): Promise<EmployeeTagAssignment[]> {
  const { data, error } = await supabase.rpc('set_employee_tags', {
    p_employee_id: employeeId,
    p_tag_ids: tagIds,
  })
  if (error) throw error
  return (data ?? []) as EmployeeTagAssignment[]
}

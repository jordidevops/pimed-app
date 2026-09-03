import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type Employee = Database['api']['Views']['employees']['Row']
export type EmployeeInsert = Database['api']['Views']['employees']['Insert']
export type EmployeeUpdate = Database['api']['Views']['employees']['Update']

export type EmployeeHrProfile = Database['api']['Views']['employee_hr_profiles']['Row']
export type EmployeeHrProfileUpdate = Database['api']['Views']['employee_hr_profiles']['Update']

// ─── Error normalisation ───────────────────────────────────────────────────────

export function normalizeEmployeeError(
  error: unknown,
): 'unauthorized' | 'not_found' | 'generic' {
  if (typeof error === 'object' && error !== null) {
    const e = error as { code?: string; status?: number }
    if (e.code === '42501' || e.status === 403) return 'unauthorized'
    if (e.code === 'PGRST116' || e.status === 404) return 'not_found'
  }
  return 'generic'
}

// ─── API calls ────────────────────────────────────────────────────────────────

export interface GetEmployeesFilters {
  siteId?: string | null
}

export async function getEmployees(filters?: GetEmployeesFilters): Promise<Employee[]> {
  let query = supabase.from('employees').select('*').order('full_name', { ascending: true })
  if (filters?.siteId) query = query.eq('site_id', filters.siteId)
  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export async function getEmployeeById(id: string): Promise<Employee | null> {
  const { data, error } = await supabase
    .from('employees')
    .select('*')
    .eq('id', id)
    .maybeSingle()
  if (error) throw error
  return data
}

export async function getEmployeeHrProfile(id: string): Promise<EmployeeHrProfile | null> {
  const { data, error } = await supabase
    .from('employee_hr_profiles')
    .select('id, tenant_id, document_id, metadata, created_at, updated_at')
    .eq('id', id)
    .maybeSingle()
  if (error) throw error
  return data as EmployeeHrProfile | null
}

export async function updateEmployeeHrProfile(
  id: string,
  params: Pick<EmployeeHrProfileUpdate, 'document_id' | 'metadata'>,
): Promise<EmployeeHrProfile> {
  const { data, error } = await supabase
    .from('employee_hr_profiles')
    .update(params)
    .eq('id', id)
    .select('id, tenant_id, document_id, metadata, created_at, updated_at')
    .single()
  if (error) throw error
  return data as EmployeeHrProfile
}

export interface CreateEmployeeParams {
  tenant_id: string
  full_name: string
  preferred_name?: string | null
  legal_name?: string | null
  employee_code?: string | null
  email?: string | null
  phone?: string | null
  job_position_id?: string | null
  status: string
  starts_on?: string | null
  ends_on?: string | null
  weekly_hours?: number | null
  department_id?: string | null
  site_id?: string | null
  attendance_geo_enabled?: boolean | null
  punch_only_at_stations?: boolean | null
  attendance_work_profile?: string | null
}

export async function createEmployee(params: CreateEmployeeParams): Promise<Employee> {
  const { data, error } = await supabase.from('employees').insert(params).select().single()
  if (error) throw error
  return data
}

export interface UpdateEmployeeParams {
  full_name?: string
  preferred_name?: string | null
  legal_name?: string | null
  employee_code?: string | null
  user_id?: string | null
  email?: string | null
  phone?: string | null
  job_position_id?: string | null
  manager_employee_id?: string | null
  status?: string
  starts_on?: string | null
  ends_on?: string | null
  weekly_hours?: number | null
  department_id?: string | null
  site_id?: string | null
  attendance_geo_enabled?: boolean | null
  punch_only_at_stations?: boolean | null
  attendance_work_profile?: string | null
}

export async function updateEmployee(id: string, params: UpdateEmployeeParams): Promise<Employee> {
  const { data, error } = await supabase
    .from('employees')
    .update(params)
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data
}

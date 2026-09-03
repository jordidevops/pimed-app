import { supabase } from '@/lib/supabase'

export interface OrgTreeNode {
  id: string
  manager_employee_id: string | null
  full_name: string | null
  preferred_name: string | null
  job_position_name: string | null
  job_position_id: string | null
  department_id: string | null
  site_id: string | null
  status: string | null
  photo_object_path: string | null
  depth: number
  path: string[]
}

export interface DirectReport {
  id: string
  full_name: string | null
  preferred_name: string | null
  job_position_name: string | null
  job_position_id: string | null
  department_id: string | null
  site_id: string | null
  status: string | null
  photo_object_path: string | null
}

export async function getEmployeeOrgTree(
  rootEmployeeId?: string | null,
  maxDepth = 8,
): Promise<OrgTreeNode[]> {
  const { data, error } = await supabase.rpc('get_employee_org_tree', {
    p_root_employee_id: rootEmployeeId ?? null,
    p_max_depth: maxDepth,
  })
  if (error) throw error
  return (data ?? []) as OrgTreeNode[]
}

export async function getEmployeeDirectReports(employeeId: string): Promise<DirectReport[]> {
  const { data, error } = await supabase.rpc('get_employee_direct_reports', {
    p_employee_id: employeeId,
  })
  if (error) throw error
  return (data ?? []) as DirectReport[]
}

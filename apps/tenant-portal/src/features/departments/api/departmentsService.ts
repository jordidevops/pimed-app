import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type Department = Database['api']['Views']['departments']['Row']
export type DepartmentInsert = Database['api']['Views']['departments']['Insert']
export type DepartmentUpdate = Database['api']['Views']['departments']['Update']

// ─── Error normalisation ───────────────────────────────────────────────────────

/**
 * Maps a raw Supabase/PostgREST error into a stable string key suitable for
 * display via i18n. Handles RLS policy violations (42501 / HTTP 403) and
 * common validation codes before falling back to 'generic'.
 */
export function normalizeDeptError(
  error: unknown,
): 'unauthorized' | 'not_found' | 'generic' {
  if (typeof error === 'object' && error !== null) {
    const e = error as { code?: string; status?: number; message?: string }
    if (e.code === '42501' || e.status === 403) return 'unauthorized'
    if (e.code === 'PGRST116' || e.status === 404) return 'not_found'
  }
  return 'generic'
}

// ─── Tree helpers ─────────────────────────────────────────────────────────────

/**
 * Returns the ancestor chain from the root down to (and including) `departmentId`.
 * Used to render breadcrumbs. Returns [] when departmentId is null (root).
 */
export function getAncestors(
  departments: Department[],
  departmentId: string | null,
): Department[] {
  if (!departmentId) return []
  const dept = departments.find((d) => d.id === departmentId)
  if (!dept) return []
  return [...getAncestors(departments, dept.parent_id ?? null), dept]
}

/**
 * Recursively collects all descendant IDs under a given node.
 * Used to exclude a node and its subtree from the parent selector (circular guard).
 */
export function getDescendantIds(
  departments: Department[],
  departmentId: string,
): string[] {
  const children = departments.filter((d) => d.parent_id === departmentId)
  return children.flatMap((c) => [c.id!, ...getDescendantIds(departments, c.id!)])
}

// ─── API calls ────────────────────────────────────────────────────────────────

/** Fetches all departments visible to the current tenant (RLS-filtered). */
export async function getDepartments(): Promise<Department[]> {
  const { data, error } = await supabase
    .from('departments')
    .select('*')
    .order('name', { ascending: true })

  if (error) throw error
  return data ?? []
}

export interface CreateDepartmentParams {
  tenant_id: string
  name: string
  code?: string | null
  parent_id?: string | null
  manager_employee_id?: string | null
  attendance_geo_enabled?: boolean | null
}

export async function createDepartment(
  params: CreateDepartmentParams,
): Promise<Department> {
  const { data, error } = await supabase
    .from('departments')
    .insert(params)
    .select()
    .single()

  if (error) throw error
  return data
}

export interface UpdateDepartmentParams {
  name?: string
  code?: string | null
  parent_id?: string | null
  manager_employee_id?: string | null
  is_active?: boolean
  attendance_geo_enabled?: boolean | null
}

export async function updateDepartment(
  id: string,
  params: UpdateDepartmentParams,
): Promise<Department> {
  const { data, error } = await supabase
    .from('departments')
    .update(params)
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data
}

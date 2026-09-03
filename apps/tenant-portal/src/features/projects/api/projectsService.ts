import { supabase } from '@/lib/supabase'
import type { Database, Json } from '@/types/database.types'

export type Project = Database['api']['Views']['projects']['Row']
export type ProjectUpdate = Database['api']['Views']['projects']['Update']

/** Project row from list RPC — may include joined client/site fields. */
export type ProjectListItem = Project & {
  client_display_name?: string | null
  contact_site_name?: string | null
  contact_site_address?: string | null
  contact_site_city?: string | null
  contact_site_postal_code?: string | null
}

export interface ProjectListParams {
  page: number
  pageSize: number
  q: string
  status: string
  type: string
  siteId: string
  departmentId: string
  plannedStartFrom: string
  plannedStartTo: string
  sortField: string
  sortDirection: 'asc' | 'desc'
  createdBy?: string
  openOnly?: boolean
}

export interface ProjectListResponse {
  items: ProjectListItem[]
  totalCount: number
  page: number
  pageSize: number
}

export interface CreateProjectParams {
  p_tenant_id: string
  p_name: string
  p_type?: 'internal' | 'work_order' | 'maintenance'
  p_description?: string
  p_status?: string
  p_visibility?: 'private' | 'department' | 'company'
  p_department_id?: string
  p_site_id?: string
  p_location_id?: string
  p_client_id?: string
  p_contact_site_id?: string
  p_planned_start?: string
  p_planned_end?: string
}

export async function getProjectsPage(
  tenantId: string,
  params: ProjectListParams,
): Promise<ProjectListResponse> {
  const { data, error } = await supabase.rpc('list_projects_paginated', {
    p_tenant_id: tenantId,
    p_page: params.page,
    p_page_size: params.pageSize,
    p_query: params.q || undefined,
    p_status: params.status || undefined,
    p_type: params.type || undefined,
    p_site_id: params.siteId || undefined,
    p_department_id: params.departmentId || undefined,
    p_planned_start_from: params.plannedStartFrom || undefined,
    p_planned_start_to: params.plannedStartTo || undefined,
    p_sort_field: params.sortField || 'created_at',
    p_sort_direction: params.sortDirection || 'desc',
    p_created_by: params.createdBy || undefined,
    p_open_only: params.openOnly ?? false,
  })

  if (error) throw error

  const row = Array.isArray(data) ? data[0] : null
  const items = ((row?.items ?? []) as ProjectListItem[])
  const totalCount = typeof row?.total_count === 'number'
    ? row.total_count
    : typeof row?.total_count === 'string'
      ? Number(row.total_count)
      : 0

  return {
    items,
    totalCount,
    page: typeof row?.page === 'number' ? row.page : params.page,
    pageSize: typeof row?.page_size === 'number' ? row.page_size : params.pageSize,
  }
}

export async function countProjects(
  tenantId: string,
  opts: {
    type?: string
    openOnly?: boolean
    plannedStartFrom?: string
    plannedStartTo?: string
  } = {},
): Promise<number> {
  const { data, error } = await supabase.rpc('count_projects', {
    p_tenant_id: tenantId,
    p_type: opts.type || undefined,
    p_open_only: opts.openOnly ?? false,
    p_planned_start_from: opts.plannedStartFrom || undefined,
    p_planned_start_to: opts.plannedStartTo || undefined,
  })
  if (error) throw error
  return typeof data === 'number' ? data : Number(data ?? 0)
}

export async function getProject(id: string): Promise<Project> {
  const { data, error } = await supabase
    .from('projects')
    .select('*')
    .eq('id', id)
    .single()

  if (error) throw error
  return data
}

export async function getProjectsByClientId(clientId: string): Promise<Project[]> {
  const { data, error } = await supabase
    .from('projects')
    .select('*')
    .eq('client_id', clientId)
    .order('planned_start', { ascending: false, nullsFirst: false })
    .order('created_at', { ascending: false })
    .limit(100)

  if (error) throw error
  return data ?? []
}

export async function createProject(params: CreateProjectParams): Promise<string> {
  const { data, error } = await supabase.rpc('create_project', params)
  if (error) throw error
  return data as string
}

export async function updateProject(
  id: string,
  params: ProjectUpdate,
): Promise<void> {
  const patch: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(params as Record<string, unknown>)) {
    if (value !== undefined) {
      patch[key] = value
    }
  }

  const { error } = await supabase.rpc('update_project', {
    p_id: id,
    p_patch: patch as Json,
  })

  if (error) throw error
}

/** Field workers (members) can edit work notes without full project-manager rights. */
export async function setProjectWorkNotes(
  id: string,
  html: string,
): Promise<void> {
  const { error } = await supabase.rpc('set_project_work_notes', {
    p_id: id,
    p_html: html,
  })
  if (error) throw error
}

export async function deleteProject(id: string): Promise<void> {
  const { error } = await supabase.from('projects').delete().eq('id', id)
  if (error) throw error
}

export interface FollowUpWorkOrderResult {
  project_id: string
  moved_task_count: number
  source_project_id: string
}

/** Create a corrective WO linked to an inspection visit; optionally move open finding tasks. */
export async function createFollowUpWorkOrder(params: {
  sourceProjectId: string
  name?: string | null
  moveOpenTasks?: boolean
  sourceRunId?: string | null
}): Promise<FollowUpWorkOrderResult> {
  const { data, error } = await supabase.rpc('create_follow_up_work_order', {
    p_source_project_id: params.sourceProjectId,
    p_name: params.name ?? undefined,
    p_move_open_tasks: params.moveOpenTasks ?? true,
    p_source_run_id: params.sourceRunId ?? undefined,
  })
  if (error) throw error
  const row = data as Record<string, unknown>
  return {
    project_id: String(row.project_id),
    moved_task_count: Number(row.moved_task_count ?? 0),
    source_project_id: String(row.source_project_id),
  }
}

export async function listFollowUpProjects(sourceProjectId: string): Promise<Project[]> {
  const { data, error } = await supabase
    .from('projects')
    .select('*')
    .eq('source_project_id', sourceProjectId)
    .neq('status', 'cancelled')
    .order('created_at', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function setProjectVisitIntent(
  projectId: string,
  intent: 'inspection' | 'corrective' | 'generic',
): Promise<void> {
  const { error } = await supabase.rpc('set_project_visit_intent', {
    p_id: projectId,
    p_intent: intent,
  })
  if (error) throw error
}

import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type SkillType = Database['api']['Views']['skill_types']['Row']
export type Skill = Database['api']['Views']['skills']['Row']
export type SkillLevel = Database['api']['Views']['skill_levels']['Row']
export type EmployeeSkill = Database['api']['Views']['employee_skills']['Row']

export type SkillSearchCriterion = {
  skill_id: string
  min_level_rank?: number | null
}

export type MatchedSkill = {
  skill_id: string
  skill_name: string | null
  level_name: string | null
  level_rank: number | null
}

export type SkillSearchHit = {
  employee_id: string
  full_name: string | null
  preferred_name: string | null
  photo_object_path: string | null
  site_id: string | null
  site_name: string | null
  job_position_name: string | null
  matched_skills: MatchedSkill[]
}

export type SkillSearchMatchMode = 'and' | 'or'

export type EmployeeSkillsSummary = {
  kpis: {
    headcount_visible: number
    employees_with_skills: number
    skills_in_catalog: number
    assignments: number
    coverage_pct: number
  }
  coverage_by_skill: Array<{
    skill_id: string
    skill_name: string
    skill_type_id: string
    skill_type_name: string
    employee_count: number
    avg_rank: number
    max_rank: number
  }>
  level_distribution: Array<{
    skill_type_id: string
    skill_type_name: string
    level_name: string
    level_rank: number
    assignment_count: number
  }>
  gaps: Array<{
    skill_id: string
    skill_name: string
    skill_type_name: string
    employee_count: number
    avg_rank: number
    reason: string
  }>
  definitions?: Record<string, string>
}

export async function getSkillTypes(activeOnly = true): Promise<SkillType[]> {
  let q = supabase.from('skill_types').select('*').order('name')
  if (activeOnly) q = q.eq('is_active', true)
  const { data, error } = await q
  if (error) throw error
  return data ?? []
}

export async function createSkillType(params: {
  tenant_id: string
  name: string
  color_token?: string | null
}): Promise<SkillType> {
  const { data, error } = await supabase
    .from('skill_types')
    .insert({
      tenant_id: params.tenant_id,
      name: params.name,
      color_token: params.color_token ?? null,
      is_certification_type: false,
      is_active: true,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateSkillType(params: {
  id: string
  name?: string
  is_active?: boolean
}): Promise<SkillType> {
  const patch: Record<string, unknown> = {}
  if (params.name !== undefined) patch.name = params.name
  if (params.is_active !== undefined) patch.is_active = params.is_active
  const { data, error } = await supabase
    .from('skill_types')
    .update(patch)
    .eq('id', params.id)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteSkillType(id: string): Promise<void> {
  const { error } = await supabase.from('skill_types').delete().eq('id', id)
  if (error) throw error
}

export async function getSkills(skillTypeId?: string, activeOnly = true): Promise<Skill[]> {
  let q = supabase.from('skills').select('*').order('name')
  if (skillTypeId) q = q.eq('skill_type_id', skillTypeId)
  if (activeOnly) q = q.eq('is_active', true)
  const { data, error } = await q
  if (error) throw error
  return data ?? []
}

export async function createSkill(params: {
  tenant_id: string
  skill_type_id: string
  name: string
  description?: string | null
}): Promise<Skill> {
  const { data, error } = await supabase
    .from('skills')
    .insert({
      tenant_id: params.tenant_id,
      skill_type_id: params.skill_type_id,
      name: params.name,
      description: params.description ?? null,
      is_active: true,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateSkill(params: {
  id: string
  name?: string
  description?: string | null
  is_active?: boolean
}): Promise<Skill> {
  const patch: Record<string, unknown> = {}
  if (params.name !== undefined) patch.name = params.name
  if (params.description !== undefined) patch.description = params.description
  if (params.is_active !== undefined) patch.is_active = params.is_active
  const { data, error } = await supabase
    .from('skills')
    .update(patch)
    .eq('id', params.id)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteSkill(id: string): Promise<void> {
  const { error } = await supabase.from('skills').delete().eq('id', id)
  if (error) throw error
}

export async function getSkillLevels(skillTypeId: string): Promise<SkillLevel[]> {
  const { data, error } = await supabase
    .from('skill_levels')
    .select('*')
    .eq('skill_type_id', skillTypeId)
    .order('rank', { ascending: true })
  if (error) throw error
  return data ?? []
}

export async function getSkillLevelsByTypeIds(typeIds: string[]): Promise<SkillLevel[]> {
  if (typeIds.length === 0) return []
  const { data, error } = await supabase
    .from('skill_levels')
    .select('*')
    .in('skill_type_id', typeIds)
    .order('rank', { ascending: true })
  if (error) throw error
  return data ?? []
}

export async function createSkillLevel(params: {
  skill_type_id: string
  name: string
  rank: number
  is_default?: boolean
}): Promise<SkillLevel> {
  const { data, error } = await supabase
    .from('skill_levels')
    .insert({
      skill_type_id: params.skill_type_id,
      name: params.name,
      rank: params.rank,
      is_default: params.is_default ?? false,
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateSkillLevel(params: {
  id: string
  name?: string
  rank?: number
  is_default?: boolean
}): Promise<SkillLevel> {
  const patch: Record<string, unknown> = {}
  if (params.name !== undefined) patch.name = params.name
  if (params.rank !== undefined) patch.rank = params.rank
  if (params.is_default !== undefined) patch.is_default = params.is_default
  const { data, error } = await supabase
    .from('skill_levels')
    .update(patch)
    .eq('id', params.id)
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteSkillLevel(id: string): Promise<void> {
  const { error } = await supabase.from('skill_levels').delete().eq('id', id)
  if (error) throw error
}

export async function getEmployeeSkills(employeeId: string): Promise<EmployeeSkill[]> {
  const { data, error } = await supabase
    .from('employee_skills')
    .select('*')
    .eq('employee_id', employeeId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function upsertEmployeeSkill(params: {
  tenant_id: string
  employee_id: string
  skill_id: string
  level_id?: string | null
  notes?: string | null
}): Promise<EmployeeSkill> {
  const { data: existing } = await supabase
    .from('employee_skills')
    .select('id')
    .eq('employee_id', params.employee_id)
    .eq('skill_id', params.skill_id)
    .maybeSingle()

  if (existing?.id) {
    const { data, error } = await supabase
      .from('employee_skills')
      .update({
        level_id: params.level_id ?? null,
        notes: params.notes ?? null,
        last_assessed_on: new Date().toISOString().slice(0, 10),
      })
      .eq('id', existing.id)
      .select()
      .single()
    if (error) throw error
    return data
  }

  const { data, error } = await supabase
    .from('employee_skills')
    .insert({
      tenant_id: params.tenant_id,
      employee_id: params.employee_id,
      skill_id: params.skill_id,
      level_id: params.level_id ?? null,
      notes: params.notes ?? null,
      acquired_on: new Date().toISOString().slice(0, 10),
    })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteEmployeeSkill(id: string): Promise<void> {
  const { error } = await supabase.from('employee_skills').delete().eq('id', id)
  if (error) throw error
}

/** @deprecated Prefer searchEmployeesBySkills */
export async function searchEmployeesBySkill(
  skillId: string,
  minLevelRank?: number | null,
): Promise<
  Array<{
    employee_id: string
    full_name: string | null
    preferred_name: string | null
    skill_id: string
    skill_name: string | null
    level_id: string | null
    level_name: string | null
    level_rank: number | null
  }>
> {
  const { data, error } = await supabase.rpc('search_employees_by_skill', {
    p_skill_id: skillId,
    p_min_level_rank: minLevelRank ?? null,
  })
  if (error) throw error
  return data ?? []
}

export async function searchEmployeesBySkills(params: {
  criteria: SkillSearchCriterion[]
  matchMode?: SkillSearchMatchMode
  siteId?: string | null
  limit?: number
}): Promise<SkillSearchHit[]> {
  const { data, error } = await supabase.rpc('search_employees_by_skills', {
    p_criteria: params.criteria,
    p_match_mode: params.matchMode ?? 'and',
    p_site_id: params.siteId ?? null,
    p_limit: params.limit ?? 48,
  })
  if (error) throw error
  return (data ?? []).map((row) => ({
    employee_id: row.employee_id,
    full_name: row.full_name,
    preferred_name: row.preferred_name,
    photo_object_path: row.photo_object_path,
    site_id: row.site_id,
    site_name: row.site_name,
    job_position_name: row.job_position_name,
    matched_skills: Array.isArray(row.matched_skills)
      ? (row.matched_skills as MatchedSkill[])
      : typeof row.matched_skills === 'string'
        ? (JSON.parse(row.matched_skills) as MatchedSkill[])
        : [],
  }))
}

export async function getEmployeeSkillsSummary(siteId?: string | null): Promise<EmployeeSkillsSummary> {
  const { data, error } = await supabase.rpc('employee_skills_summary', {
    p_site_id: siteId ?? null,
  })
  if (error) throw error
  return data as EmployeeSkillsSummary
}

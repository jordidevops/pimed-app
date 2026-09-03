import { supabase } from '@/lib/supabase'

export type MaintenanceFrequency = 'daily' | 'weekly' | 'monthly' | 'yearly'
export type MaintenanceEntityType = 'contact' | 'contact_site' | 'site' | 'location' | 'asset'
export type MaintenanceLocale = 'ca' | 'es' | 'en'
export type MaintenanceArchetype =
  | 'field_service'
  | 'practice'
  | 'hospitality'
  | 'workshop_maker'
  | 'generic'
export type ChecklistVersionStatus = 'draft' | 'published' | 'archived'

export const MAINTENANCE_FREQUENCIES: MaintenanceFrequency[] = ['daily', 'weekly', 'monthly', 'yearly']
export const MAINTENANCE_ENTITY_TYPES: MaintenanceEntityType[] = [
  'contact',
  'contact_site',
  'site',
  'location',
  'asset',
]
export const MAINTENANCE_LOCALES: MaintenanceLocale[] = ['ca', 'es', 'en']
export const DEFAULT_MAINTENANCE_TIMEZONE = 'Europe/Madrid'

export interface MaintenancePlan {
  id: string
  tenant_id: string | null
  name: string
  description: string | null
  locale: MaintenanceLocale
  category: string
  vertical: string
  archetype: MaintenanceArchetype
  metadata: Record<string, unknown>
  catalog_version: number
  frequency: MaintenanceFrequency
  interval_count: number
  byweekday: number[] | null
  bymonthday: number | null
  timezone: string
  lead_days: number
  is_active: boolean
  is_archived: boolean
  created_by: string | null
  created_at: string | null
  updated_at: string | null
  checklists?: MaintenancePlanChecklist[]
}

export interface MaintenancePlanChecklist {
  id: string
  plan_id: string
  template_id: string
  position: number
}

export interface MaintenancePlanFork {
  id: string
  source_plan_id: string
  source_version_at_fork: number
  tenant_plan_id: string
  tenant_id: string
  created_at: string | null
}

export interface MaintenancePlanAssignment {
  id: string
  tenant_id: string
  plan_id: string
  entity_type: MaintenanceEntityType
  entity_id: string
  frequency: MaintenanceFrequency
  interval_count: number
  byweekday: number[] | null
  bymonthday: number | null
  timezone: string
  lead_days: number
  next_due_at: string | null
  valid_from: string | null
  valid_to: string | null
  is_active: boolean
  created_at: string | null
  updated_at: string | null
}

/** One template linked to a plan, resolved with its published content. */
export interface PlanChecklistDetail extends MaintenancePlanChecklist {
  template_name: string
  template_kind: string
  template_locale: string
  template_category: string
  version_id: string | null
  version_number: number | null
  version_status: ChecklistVersionStatus | null
  items: PlanChecklistItemPreview[]
}

export interface PlanChecklistItemPreview {
  id: string
  position: number
  title: string
  description_public: string | null
  description_internal: string | null
  is_required: boolean
  include_in_report: boolean
  response_type: string
  review_point_id: string | null
}

export interface MaintenancePlanDetail {
  plan: MaintenancePlan
  checklists: PlanChecklistDetail[]
  fork: MaintenancePlanFork | null
}

/** Published tenant template that can be linked to a plan. */
export interface PublishedTemplateOption {
  id: string
  name: string
  kind: string
  locale: string
  category: string
  version_id: string
  version_number: number
  item_count: number
}

/**
 * A tenant plan cloned from the platform library whose source has moved on.
 * `update_available` compares the catalog version captured at fork time with
 * the source plan's current catalog version.
 */
export interface PlanUpdateStatus {
  tenant_plan_id: string
  source_plan_id: string
  source_plan_name: string
  source_version_at_fork: number
  source_catalog_version: number
  update_available: boolean
}

export interface PlanListFilters {
  search?: string
  locale?: MaintenanceLocale | null
  category?: string | null
  vertical?: string | null
  archetype?: MaintenanceArchetype | null
  includeArchived?: boolean
  page?: number
  pageSize?: number
}

export interface Paginated<T> {
  rows: T[]
  total: number
  page: number
  pageSize: number
  hasMore: boolean
}

const PLAN_COLUMNS = `
  id, tenant_id, name, description, locale, category, vertical, archetype,
  metadata, catalog_version, frequency, interval_count, byweekday, bymonthday,
  timezone, lead_days, is_active, is_archived, created_by, created_at, updated_at
`

const DEFAULT_PAGE_SIZE = 20

function asRecord(raw: unknown): Record<string, unknown> {
  return (raw ?? {}) as Record<string, unknown>
}

function parseMetadata(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {}
  return raw as Record<string, unknown>
}

function parseByweekday(raw: unknown): number[] | null {
  if (!Array.isArray(raw)) return null
  const days = raw.map((d) => Number(d)).filter((d) => Number.isInteger(d) && d >= 0 && d <= 6)
  return days.length > 0 ? days : null
}

function mapPlan(raw: unknown): MaintenancePlan {
  const row = asRecord(raw)
  return {
    id: String(row.id),
    tenant_id: row.tenant_id != null ? String(row.tenant_id) : null,
    name: String(row.name ?? ''),
    description: row.description != null ? String(row.description) : null,
    locale: (row.locale as MaintenanceLocale) ?? 'ca',
    category: String(row.category ?? 'general'),
    vertical: String(row.vertical ?? 'generic'),
    archetype: (row.archetype as MaintenanceArchetype) ?? 'generic',
    metadata: parseMetadata(row.metadata),
    catalog_version: Number(row.catalog_version ?? 1),
    frequency: (row.frequency as MaintenanceFrequency) ?? 'monthly',
    interval_count: Number(row.interval_count ?? 1),
    byweekday: parseByweekday(row.byweekday),
    bymonthday: row.bymonthday != null ? Number(row.bymonthday) : null,
    timezone: String(row.timezone ?? DEFAULT_MAINTENANCE_TIMEZONE),
    lead_days: Number(row.lead_days ?? 0),
    is_active: row.is_active !== false,
    is_archived: row.is_archived === true,
    created_by: row.created_by != null ? String(row.created_by) : null,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapPlanChecklist(raw: unknown): MaintenancePlanChecklist {
  const row = asRecord(raw)
  return {
    id: String(row.id),
    plan_id: String(row.plan_id),
    template_id: String(row.template_id),
    position: Number(row.position ?? 0),
  }
}

function mapFork(raw: unknown): MaintenancePlanFork {
  const row = asRecord(raw)
  return {
    id: String(row.id),
    source_plan_id: String(row.source_plan_id),
    source_version_at_fork: Number(row.source_version_at_fork ?? 1),
    tenant_plan_id: String(row.tenant_plan_id),
    tenant_id: String(row.tenant_id),
    created_at: (row.created_at as string | null) ?? null,
  }
}

function mapAssignment(raw: unknown): MaintenancePlanAssignment {
  const row = asRecord(raw)
  return {
    id: String(row.id),
    tenant_id: String(row.tenant_id),
    plan_id: String(row.plan_id),
    entity_type: row.entity_type as MaintenanceEntityType,
    entity_id: String(row.entity_id),
    frequency: (row.frequency as MaintenanceFrequency) ?? 'monthly',
    interval_count: Number(row.interval_count ?? 1),
    byweekday: parseByweekday(row.byweekday),
    bymonthday: row.bymonthday != null ? Number(row.bymonthday) : null,
    timezone: String(row.timezone ?? DEFAULT_MAINTENANCE_TIMEZONE),
    lead_days: Number(row.lead_days ?? 0),
    next_due_at: (row.next_due_at as string | null) ?? null,
    valid_from: (row.valid_from as string | null) ?? null,
    valid_to: (row.valid_to as string | null) ?? null,
    is_active: row.is_active !== false,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapItemPreview(raw: unknown): PlanChecklistItemPreview {
  const row = asRecord(raw)
  return {
    id: String(row.id),
    position: Number(row.position ?? 0),
    title: String(row.title ?? ''),
    description_public: row.description_public != null ? String(row.description_public) : null,
    description_internal: row.description_internal != null ? String(row.description_internal) : null,
    is_required: row.is_required === true,
    include_in_report: row.include_in_report === true,
    response_type: String(row.response_type ?? 'checkbox'),
    review_point_id: row.review_point_id != null ? String(row.review_point_id) : null,
  }
}

function escapeForOr(value: string): string {
  // PostgREST `or=` uses comma/parenthesis as separators.
  return value.replace(/[,()]/g, ' ').trim()
}

function paginate(page?: number, pageSize?: number): { page: number; size: number; from: number; to: number } {
  const size = Math.max(1, Math.min(100, pageSize ?? DEFAULT_PAGE_SIZE))
  const current = Math.max(1, page ?? 1)
  const from = (current - 1) * size
  return { page: current, size, from, to: from + size - 1 }
}

function withChecklists(rows: unknown[]): MaintenancePlan[] {
  return rows.map((raw) => {
    const row = asRecord(raw)
    const plan = mapPlan(row)
    const checklists = ((row.checklists as unknown[]) ?? [])
      .map(mapPlanChecklist)
      .sort((a, b) => a.position - b.position)
    return { ...plan, checklists }
  })
}

async function fetchPlans(
  scope: { tenantId: string } | { platform: true },
  filters: PlanListFilters = {},
): Promise<Paginated<MaintenancePlan>> {
  const { page, size, from, to } = paginate(filters.page, filters.pageSize)

  let query = supabase
    .from('maintenance_plans')
    .select(`${PLAN_COLUMNS}, checklists:maintenance_plan_checklists(id, plan_id, template_id, position)`, {
      count: 'exact',
    })

  if ('tenantId' in scope) {
    query = query.eq('tenant_id', scope.tenantId)
  } else {
    query = query.is('tenant_id', null).eq('is_active', true)
  }

  if (!filters.includeArchived) query = query.eq('is_archived', false)
  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category.toLowerCase())
  if (filters.vertical) query = query.eq('vertical', filters.vertical.toLowerCase())
  if (filters.archetype) query = query.eq('archetype', filters.archetype)

  const search = escapeForOr(filters.search ?? '')
  if (search) {
    query = query.or(`name.ilike.%${search}%,description.ilike.%${search}%`)
  }

  const { data, error, count } = await query.order('name', { ascending: true }).range(from, to)
  if (error) throw error

  const rows = withChecklists(data ?? [])
  const total = count ?? rows.length
  return { rows, total, page, pageSize: size, hasMore: from + rows.length < total }
}

export async function listTenantPlans(
  tenantId: string,
  filters: PlanListFilters = {},
): Promise<Paginated<MaintenancePlan>> {
  return fetchPlans({ tenantId }, filters)
}

export async function listPlatformPlans(
  filters: PlanListFilters = {},
): Promise<Paginated<MaintenancePlan>> {
  return fetchPlans({ platform: true }, filters)
}

/**
 * Plan plus its ordered checklists, each resolved to the template name and a
 * preview of the published items. Used both for the tenant editor and for the
 * read-only preview of platform library plans.
 */
export async function getPlanDetail(planId: string): Promise<MaintenancePlanDetail> {
  const { data: planRow, error: planError } = await supabase
    .from('maintenance_plans')
    .select(PLAN_COLUMNS)
    .eq('id', planId)
    .single()
  if (planError) throw planError

  const plan = mapPlan(planRow)

  const { data: linkRows, error: linkError } = await supabase
    .from('maintenance_plan_checklists')
    .select('id, plan_id, template_id, position')
    .eq('plan_id', planId)
    .order('position', { ascending: true })
  if (linkError) throw linkError

  const links = (linkRows ?? []).map(mapPlanChecklist)

  const { data: forkRows, error: forkError } = await supabase
    .from('maintenance_plan_forks')
    .select('id, source_plan_id, source_version_at_fork, tenant_plan_id, tenant_id, created_at')
    .eq('tenant_plan_id', planId)
    .limit(1)
  if (forkError) throw forkError
  const fork = (forkRows ?? []).length > 0 ? mapFork(forkRows![0]) : null

  if (links.length === 0) {
    return { plan, checklists: [], fork }
  }

  const templateIds = [...new Set(links.map((l) => l.template_id))]

  const { data: templateRows, error: tplError } = await supabase
    .from('checklist_templates')
    .select('id, name, kind, locale, category')
    .in('id', templateIds)
  if (tplError) throw tplError

  const templatesById = new Map(
    (templateRows ?? []).map((raw) => {
      const row = asRecord(raw)
      return [String(row.id), row] as const
    }),
  )

  const { data: versionRows, error: verError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number, status')
    .in('template_id', templateIds)
    .order('version_number', { ascending: false })
  if (verError) throw verError

  // Prefer the published version; fall back to the newest one so drafts still preview.
  const versionByTemplate = new Map<string, Record<string, unknown>>()
  for (const raw of versionRows ?? []) {
    const row = asRecord(raw)
    const templateId = String(row.template_id)
    const current = versionByTemplate.get(templateId)
    if (!current) {
      versionByTemplate.set(templateId, row)
      continue
    }
    if (current.status !== 'published' && row.status === 'published') {
      versionByTemplate.set(templateId, row)
    }
  }

  const versionIds = [...versionByTemplate.values()].map((v) => String(v.id))
  const itemsByVersion = new Map<string, PlanChecklistItemPreview[]>()

  if (versionIds.length > 0) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select(
        'id, version_id, position, title, description_public, description_internal, is_required, include_in_report, response_type, review_point_id',
      )
      .in('version_id', versionIds)
      .order('position', { ascending: true })
    if (itemError) throw itemError

    for (const raw of itemRows ?? []) {
      const row = asRecord(raw)
      const versionId = String(row.version_id)
      const bucket = itemsByVersion.get(versionId) ?? []
      bucket.push(mapItemPreview(row))
      itemsByVersion.set(versionId, bucket)
    }
  }

  const checklists: PlanChecklistDetail[] = links.map((link) => {
    const template = templatesById.get(link.template_id)
    const version = versionByTemplate.get(link.template_id)
    const versionId = version ? String(version.id) : null
    return {
      ...link,
      template_name: template ? String(template.name ?? '') : link.template_id,
      template_kind: template ? String(template.kind ?? 'todo') : 'todo',
      template_locale: template ? String(template.locale ?? 'ca') : 'ca',
      template_category: template ? String(template.category ?? 'general') : 'general',
      version_id: versionId,
      version_number: version ? Number(version.version_number ?? 0) : null,
      version_status: version ? ((version.status as ChecklistVersionStatus) ?? null) : null,
      items: versionId ? (itemsByVersion.get(versionId) ?? []) : [],
    }
  })

  return { plan, checklists, fork }
}

async function assertTenantPlan(planId: string, tenantId: string): Promise<void> {
  const { data, error } = await supabase
    .from('maintenance_plans')
    .select('id, tenant_id')
    .eq('id', planId)
    .single()
  if (error) throw error
  const owner = asRecord(data).tenant_id
  if (owner == null) throw new Error('platform_plan_is_read_only')
  if (String(owner) !== tenantId) throw new Error('plan_tenant_mismatch')
}

export interface PlanWriteInput {
  name: string
  description?: string | null
  locale?: MaintenanceLocale
  category?: string
  vertical?: string
  archetype?: MaintenanceArchetype
  frequency?: MaintenanceFrequency
  interval_count?: number
  byweekday?: number[] | null
  bymonthday?: number | null
  timezone?: string
  lead_days?: number
  is_active?: boolean
}

export async function createPlan(tenantId: string, input: PlanWriteInput): Promise<string> {
  const { data, error } = await supabase
    .from('maintenance_plans')
    .insert({
      tenant_id: tenantId,
      name: input.name.trim(),
      description: input.description?.trim() || null,
      locale: input.locale ?? 'ca',
      category: (input.category ?? 'general').trim().toLowerCase() || 'general',
      vertical: (input.vertical ?? 'generic').trim().toLowerCase() || 'generic',
      archetype: input.archetype ?? 'generic',
      frequency: input.frequency ?? 'monthly',
      interval_count: Math.max(1, input.interval_count ?? 1),
      byweekday: input.byweekday ?? null,
      bymonthday: input.bymonthday ?? null,
      timezone: input.timezone ?? DEFAULT_MAINTENANCE_TIMEZONE,
      lead_days: Math.max(0, input.lead_days ?? 0),
      is_active: input.is_active ?? true,
      is_archived: false,
    })
    .select('id')
    .single()
  if (error) throw error
  return String(asRecord(data).id)
}

/** Tenant plans only — platform rows are managed from the admin portal. */
export async function updatePlan(
  planId: string,
  tenantId: string,
  patch: Partial<PlanWriteInput>,
): Promise<void> {
  await assertTenantPlan(planId, tenantId)

  const payload: Record<string, unknown> = {}
  if (patch.name !== undefined) payload.name = patch.name.trim()
  if (patch.description !== undefined) payload.description = patch.description?.trim() || null
  if (patch.locale !== undefined) payload.locale = patch.locale
  if (patch.category !== undefined) {
    payload.category = patch.category.trim().toLowerCase() || 'general'
  }
  if (patch.vertical !== undefined) {
    payload.vertical = patch.vertical.trim().toLowerCase() || 'generic'
  }
  if (patch.archetype !== undefined) payload.archetype = patch.archetype
  if (patch.frequency !== undefined) payload.frequency = patch.frequency
  if (patch.interval_count !== undefined) {
    payload.interval_count = Math.max(1, patch.interval_count)
  }
  if (patch.byweekday !== undefined) payload.byweekday = patch.byweekday
  if (patch.bymonthday !== undefined) payload.bymonthday = patch.bymonthday
  if (patch.timezone !== undefined) payload.timezone = patch.timezone
  if (patch.lead_days !== undefined) payload.lead_days = Math.max(0, patch.lead_days)
  if (patch.is_active !== undefined) payload.is_active = patch.is_active

  if (Object.keys(payload).length === 0) return

  const { error } = await supabase.from('maintenance_plans').update(payload).eq('id', planId)
  if (error) throw error
}

export async function archivePlan(planId: string, tenantId: string): Promise<void> {
  await assertTenantPlan(planId, tenantId)
  const { error } = await supabase
    .from('maintenance_plans')
    .update({ is_archived: true, is_active: false })
    .eq('id', planId)
  if (error) throw error
}

/** Deep clone (plan + checklists + review points) via the platform RPC. */
export async function clonePlan(
  sourcePlanId: string,
  tenantId: string,
  name?: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('clone_maintenance_plan', {
    p_source_plan_id: sourcePlanId,
    p_tenant_id: tenantId,
    p_name: name?.trim() || undefined,
  })
  if (error) throw error
  return String(data)
}

export async function countUnpublishedPlanTemplates(planId: string): Promise<number> {
  const { data, error } = await supabase.rpc('maintenance_plan_unpublished_templates', {
    p_plan_id: planId,
  })
  if (error) throw error
  return Number(data ?? 0)
}

/** Replaces the plan's checklist links, keeping the given order. */
export async function setPlanChecklists(
  planId: string,
  tenantId: string,
  templateIds: string[],
): Promise<void> {
  await assertTenantPlan(planId, tenantId)

  const { error: delError } = await supabase
    .from('maintenance_plan_checklists')
    .delete()
    .eq('plan_id', planId)
  if (delError) throw delError

  const unique = [...new Set(templateIds.filter(Boolean))]
  if (unique.length === 0) return

  const { error: insError } = await supabase.from('maintenance_plan_checklists').insert(
    unique.map((templateId, index) => ({
      plan_id: planId,
      template_id: templateId,
      position: index,
    })),
  )
  if (insError) throw insError
}

/**
 * Tenant templates with a published version — the only ones a plan can link,
 * since maintenance orders apply published versions only.
 */
export async function listPublishedTenantTemplates(
  tenantId: string,
): Promise<PublishedTemplateOption[]> {
  const { data: templateRows, error: tplError } = await supabase
    .from('checklist_templates')
    .select('id, name, kind, locale, category')
    .eq('tenant_id', tenantId)
    .eq('is_active', true)
    .eq('is_archived', false)
    .order('name', { ascending: true })
  if (tplError) throw tplError

  const templates = (templateRows ?? []).map(asRecord)
  if (templates.length === 0) return []

  const templateIds = templates.map((t) => String(t.id))
  const { data: versionRows, error: verError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number, status')
    .in('template_id', templateIds)
    .eq('status', 'published')
    .order('version_number', { ascending: false })
  if (verError) throw verError

  const publishedByTemplate = new Map<string, Record<string, unknown>>()
  for (const raw of versionRows ?? []) {
    const row = asRecord(raw)
    const templateId = String(row.template_id)
    if (!publishedByTemplate.has(templateId)) publishedByTemplate.set(templateId, row)
  }

  const versionIds = [...publishedByTemplate.values()].map((v) => String(v.id))
  const itemCounts = new Map<string, number>()
  if (versionIds.length > 0) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('id, version_id')
      .in('version_id', versionIds)
    if (itemError) throw itemError
    for (const raw of itemRows ?? []) {
      const versionId = String(asRecord(raw).version_id)
      itemCounts.set(versionId, (itemCounts.get(versionId) ?? 0) + 1)
    }
  }

  const options: PublishedTemplateOption[] = []
  for (const template of templates) {
    const id = String(template.id)
    const version = publishedByTemplate.get(id)
    if (!version) continue
    const versionId = String(version.id)
    options.push({
      id,
      name: String(template.name ?? ''),
      kind: String(template.kind ?? 'todo'),
      locale: String(template.locale ?? 'ca'),
      category: String(template.category ?? 'general'),
      version_id: versionId,
      version_number: Number(version.version_number ?? 0),
      item_count: itemCounts.get(versionId) ?? 0,
    })
  }
  return options
}

/** Only tenant plans are assignable; platform plans must be cloned first. */
export async function createAssignment(params: {
  tenant_id: string
  plan_id: string
  entity_type: MaintenanceEntityType
  entity_id: string
  frequency?: MaintenanceFrequency
  interval_count?: number
  byweekday?: number[] | null
  bymonthday?: number | null
  timezone?: string
  lead_days?: number
  next_due_at?: string | null
}): Promise<string> {
  await assertTenantPlan(params.plan_id, params.tenant_id)

  const { data, error } = await supabase
    .from('maintenance_plan_assignments')
    .insert({
      tenant_id: params.tenant_id,
      plan_id: params.plan_id,
      entity_type: params.entity_type,
      entity_id: params.entity_id,
      frequency: params.frequency ?? 'monthly',
      interval_count: Math.max(1, params.interval_count ?? 1),
      byweekday: params.byweekday ?? null,
      bymonthday: params.bymonthday ?? null,
      timezone: params.timezone ?? DEFAULT_MAINTENANCE_TIMEZONE,
      lead_days: Math.max(0, params.lead_days ?? 0),
      next_due_at: params.next_due_at ?? null,
      is_active: true,
    })
    .select('id')
    .single()
  if (error) throw error
  return String(asRecord(data).id)
}

export async function listAssignments(tenantId: string): Promise<MaintenancePlanAssignment[]> {
  const { data, error } = await supabase
    .from('maintenance_plan_assignments')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('next_due_at', { ascending: true })
  if (error) throw error
  return (data ?? []).map(mapAssignment)
}

export async function listPlanUpdates(tenantId: string): Promise<PlanUpdateStatus[]> {
  const { data: forkRows, error: forkError } = await supabase
    .from('maintenance_plan_forks')
    .select('id, source_plan_id, source_version_at_fork, tenant_plan_id, tenant_id, created_at')
    .eq('tenant_id', tenantId)
  if (forkError) throw forkError

  const forks = (forkRows ?? []).map(mapFork)
  if (forks.length === 0) return []

  const sourceIds = [...new Set(forks.map((f) => f.source_plan_id))]
  const { data: sourceRows, error: sourceError } = await supabase
    .from('maintenance_plans')
    .select('id, name, catalog_version')
    .in('id', sourceIds)
  if (sourceError) throw sourceError

  const sourcesById = new Map(
    (sourceRows ?? []).map((raw) => {
      const row = asRecord(raw)
      return [String(row.id), row] as const
    }),
  )

  return forks.map((fork) => {
    const source = sourcesById.get(fork.source_plan_id)
    const catalogVersion = source ? Number(source.catalog_version ?? 1) : fork.source_version_at_fork
    return {
      tenant_plan_id: fork.tenant_plan_id,
      source_plan_id: fork.source_plan_id,
      source_plan_name: source ? String(source.name ?? '') : fork.source_plan_id,
      source_version_at_fork: fork.source_version_at_fork,
      source_catalog_version: catalogVersion,
      update_available: catalogVersion > fork.source_version_at_fork,
    }
  })
}
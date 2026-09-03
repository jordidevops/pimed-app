'use server'

import { revalidatePath } from 'next/cache'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { assertBackofficeRole } from '@/lib/platform-catalog/server'
import {
  assertArchetype,
  assertFrequency,
  assertLocale,
  asRecord,
  describeDbError,
  normalizeTaxonomy,
  nullableStr,
  num,
  pageCount,
  resolvePaging,
  sanitizeSearch,
  str,
  DEFAULT_TIMEZONE,
  type ActionResult,
  type CatalogFilters,
  type PagedResult,
} from '@/lib/platform-catalog/constants'

const PLANS_PATH = '/dashboard/settings/maintenance-plans'

const PLAN_COLUMNS =
  'id, name, description, locale, category, vertical, archetype, catalog_version, frequency, interval_count, byweekday, bymonthday, timezone, lead_days, is_active, is_archived, created_at, updated_at'

export interface PlatformMaintenancePlan {
  id: string
  name: string
  description: string | null
  locale: string
  category: string
  vertical: string
  archetype: string
  catalog_version: number
  frequency: string
  interval_count: number
  byweekday: number[] | null
  bymonthday: number | null
  timezone: string
  lead_days: number
  is_active: boolean
  is_archived: boolean
  created_at: string | null
  updated_at: string | null
  checklist_count: number
  /** Number of tenant plans cloned from this one. */
  tenant_clones: number
}

export interface PlatformPlanChecklistItem {
  id: string
  position: number
  title: string
  response_type: string
}

export interface PlatformPlanChecklist {
  template_id: string
  position: number
  template_name: string
  template_kind: string
  published_version_number: number | null
  published_item_count: number
  items: PlatformPlanChecklistItem[]
}

export interface PlatformPlanDetail {
  plan: PlatformMaintenancePlan
  checklists: PlatformPlanChecklist[]
}

export interface PublishedPlatformTemplateOption {
  id: string
  name: string
  kind: string
  locale: string
  category: string
  version_number: number
  item_count: number
}

export interface MaintenancePlanInput {
  name: string
  description?: string | null
  locale?: string
  category?: string
  vertical?: string
  archetype?: string
  frequency?: string
  interval_count?: number
  byweekday?: number[] | null
  bymonthday?: number | null
  timezone?: string
  lead_days?: number
  is_active?: boolean
  /** Ordered platform templates linked to the plan. At least one is required. */
  templateIds: string[]
}

function parseByweekday(raw: unknown): number[] | null {
  if (!Array.isArray(raw)) return null
  const days = raw.map((d) => Number(d)).filter((d) => Number.isInteger(d) && d >= 0 && d <= 6)
  return days.length > 0 ? days : null
}

function mapPlan(raw: unknown, checklistCount = 0, tenantClones = 0): PlatformMaintenancePlan {
  const row = asRecord(raw)
  return {
    id: str(row.id),
    name: str(row.name),
    description: nullableStr(row.description),
    locale: str(row.locale, 'ca'),
    category: str(row.category, 'general'),
    vertical: str(row.vertical, 'generic'),
    archetype: str(row.archetype, 'generic'),
    catalog_version: num(row.catalog_version, 1),
    frequency: str(row.frequency, 'monthly'),
    interval_count: num(row.interval_count, 1),
    byweekday: parseByweekday(row.byweekday),
    bymonthday: row.bymonthday != null ? num(row.bymonthday) : null,
    timezone: str(row.timezone, DEFAULT_TIMEZONE),
    lead_days: num(row.lead_days, 0),
    is_active: row.is_active !== false,
    is_archived: row.is_archived === true,
    created_at: nullableStr(row.created_at),
    updated_at: nullableStr(row.updated_at),
    checklist_count: checklistCount,
    tenant_clones: tenantClones,
  }
}

export async function listPlatformMaintenancePlans(
  filters: CatalogFilters = {},
): Promise<PagedResult<PlatformMaintenancePlan>> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()
  const { page, size, from, to } = resolvePaging(filters.page, filters.pageSize)

  let query = supabase
    .from('maintenance_plans')
    .select(PLAN_COLUMNS, { count: 'exact' })
    .is('tenant_id', null)

  if (!filters.includeArchived) query = query.eq('is_archived', false)
  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category.toLowerCase())
  if (filters.vertical) query = query.eq('vertical', filters.vertical.toLowerCase())
  if (filters.archetype) query = query.eq('archetype', filters.archetype)

  const search = sanitizeSearch(filters.search)
  if (search) query = query.or(`name.ilike.%${search}%,description.ilike.%${search}%`)

  const { data, error, count } = await query.order('name', { ascending: true }).range(from, to)
  if (error) throw new Error(describeDbError(error))

  const planRows = (data ?? []).map(asRecord)
  const planIds = planRows.map((row) => str(row.id))

  const checklistCounts = new Map<string, number>()
  const cloneCounts = new Map<string, number>()

  if (planIds.length > 0) {
    const { data: linkRows, error: linkError } = await supabase
      .from('maintenance_plan_checklists')
      .select('plan_id')
      .in('plan_id', planIds)
    if (linkError) throw new Error(describeDbError(linkError))
    for (const raw of linkRows ?? []) {
      const planId = str(asRecord(raw).plan_id)
      checklistCounts.set(planId, (checklistCounts.get(planId) ?? 0) + 1)
    }

    const { data: forkRows, error: forkError } = await supabase
      .from('maintenance_plan_forks')
      .select('source_plan_id')
      .in('source_plan_id', planIds)
    if (forkError) throw new Error(describeDbError(forkError))
    for (const raw of forkRows ?? []) {
      const planId = str(asRecord(raw).source_plan_id)
      cloneCounts.set(planId, (cloneCounts.get(planId) ?? 0) + 1)
    }
  }

  const total = count ?? planRows.length
  const rows = planRows.map((row) =>
    mapPlan(row, checklistCounts.get(str(row.id)) ?? 0, cloneCounts.get(str(row.id)) ?? 0),
  )

  return { rows, total, page, pageSize: size, pageCount: pageCount(total, size) }
}

export async function getPlatformMaintenancePlan(planId: string): Promise<PlatformPlanDetail> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  const { data: planRow, error: planError } = await supabase
    .from('maintenance_plans')
    .select(PLAN_COLUMNS)
    .eq('id', planId)
    .is('tenant_id', null)
    .single()
  if (planError) throw new Error(describeDbError(planError))

  const { data: linkRows, error: linkError } = await supabase
    .from('maintenance_plan_checklists')
    .select('template_id, position')
    .eq('plan_id', planId)
    .order('position', { ascending: true })
  if (linkError) throw new Error(describeDbError(linkError))

  const links = (linkRows ?? []).map((raw) => {
    const row = asRecord(raw)
    return { template_id: str(row.template_id), position: num(row.position) }
  })

  const { count: cloneCount, error: cloneError } = await supabase
    .from('maintenance_plan_forks')
    .select('id', { count: 'exact', head: true })
    .eq('source_plan_id', planId)
  if (cloneError) throw new Error(describeDbError(cloneError))

  const plan = mapPlan(planRow, links.length, cloneCount ?? 0)
  if (links.length === 0) return { plan, checklists: [] }

  const templateIds = links.map((l) => l.template_id)
  const { data: templateRows, error: templateError } = await supabase
    .from('checklist_templates')
    .select('id, name, kind')
    .in('id', templateIds)
  if (templateError) throw new Error(describeDbError(templateError))

  const templatesById = new Map(
    (templateRows ?? []).map((raw) => {
      const row = asRecord(raw)
      return [str(row.id), row] as const
    }),
  )

  const { data: versionRows, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number, status')
    .in('template_id', templateIds)
    .eq('status', 'published')
    .order('version_number', { ascending: false })
  if (versionError) throw new Error(describeDbError(versionError))

  const publishedByTemplate = new Map<string, Record<string, unknown>>()
  for (const raw of versionRows ?? []) {
    const row = asRecord(raw)
    const templateId = str(row.template_id)
    if (!publishedByTemplate.has(templateId)) publishedByTemplate.set(templateId, row)
  }

  const itemsByVersion = new Map<string, PlatformPlanChecklistItem[]>()
  const versionIds = [...publishedByTemplate.values()].map((v) => str(v.id))
  if (versionIds.length > 0) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('id, version_id, position, title, response_type')
      .in('version_id', versionIds)
      .order('position', { ascending: true })
    if (itemError) throw new Error(describeDbError(itemError))
    for (const raw of itemRows ?? []) {
      const row = asRecord(raw)
      const versionId = str(row.version_id)
      const list = itemsByVersion.get(versionId) ?? []
      list.push({
        id: str(row.id),
        position: num(row.position),
        title: str(row.title),
        response_type: str(row.response_type, 'checkbox'),
      })
      itemsByVersion.set(versionId, list)
    }
  }

  const checklists: PlatformPlanChecklist[] = links.map((link) => {
    const template = templatesById.get(link.template_id)
    const version = publishedByTemplate.get(link.template_id)
    const versionId = version ? str(version.id) : null
    const items = versionId ? (itemsByVersion.get(versionId) ?? []) : []
    return {
      template_id: link.template_id,
      position: link.position,
      template_name: template ? str(template.name) : link.template_id,
      template_kind: template ? str(template.kind, 'todo') : 'todo',
      published_version_number: version ? num(version.version_number) : null,
      published_item_count: items.length,
      items,
    }
  })

  return { plan, checklists }
}

/** Platform templates with a published version — the only linkable ones. */
export async function listPublishedPlatformTemplates(): Promise<PublishedPlatformTemplateOption[]> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  const { data: templateRows, error: templateError } = await supabase
    .from('checklist_templates')
    .select('id, name, kind, locale, category')
    .is('tenant_id', null)
    .eq('is_active', true)
    .eq('is_archived', false)
    .order('name', { ascending: true })
  if (templateError) throw new Error(describeDbError(templateError))

  const templates = (templateRows ?? []).map(asRecord)
  if (templates.length === 0) return []

  const { data: versionRows, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number')
    .in(
      'template_id',
      templates.map((t) => str(t.id)),
    )
    .eq('status', 'published')
    .order('version_number', { ascending: false })
  if (versionError) throw new Error(describeDbError(versionError))

  const publishedByTemplate = new Map<string, Record<string, unknown>>()
  for (const raw of versionRows ?? []) {
    const row = asRecord(raw)
    const templateId = str(row.template_id)
    if (!publishedByTemplate.has(templateId)) publishedByTemplate.set(templateId, row)
  }

  const versionIds = [...publishedByTemplate.values()].map((v) => str(v.id))
  const itemCounts = new Map<string, number>()
  if (versionIds.length > 0) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('id, version_id')
      .in('version_id', versionIds)
    if (itemError) throw new Error(describeDbError(itemError))
    for (const raw of itemRows ?? []) {
      const versionId = str(asRecord(raw).version_id)
      itemCounts.set(versionId, (itemCounts.get(versionId) ?? 0) + 1)
    }
  }

  const options: PublishedPlatformTemplateOption[] = []
  for (const template of templates) {
    const id = str(template.id)
    const version = publishedByTemplate.get(id)
    if (!version) continue
    options.push({
      id,
      name: str(template.name),
      kind: str(template.kind, 'todo'),
      locale: str(template.locale, 'ca'),
      category: str(template.category, 'general'),
      version_number: num(version.version_number),
      item_count: itemCounts.get(str(version.id)) ?? 0,
    })
  }
  return options
}

function buildPlanPayload(input: MaintenancePlanInput): Record<string, unknown> {
  const name = input.name.trim()
  if (!name) throw new Error('El nom del pla és obligatori.')

  const frequency = assertFrequency(input.frequency)
  // byweekday only means something for weekly plans, bymonthday for monthly ones;
  // keeping the other one null avoids misleading values after a frequency change.
  const bymonthday =
    frequency === 'monthly' && input.bymonthday != null
      ? Math.max(1, Math.min(31, Math.floor(input.bymonthday)))
      : null
  const byweekday = frequency === 'weekly' ? parseByweekday(input.byweekday) : null

  return {
    name,
    description: input.description?.trim() || null,
    locale: assertLocale(input.locale),
    category: normalizeTaxonomy(input.category, 'general'),
    vertical: normalizeTaxonomy(input.vertical, 'generic'),
    archetype: assertArchetype(input.archetype),
    frequency,
    interval_count: Math.max(1, Math.floor(input.interval_count ?? 1)),
    byweekday,
    bymonthday,
    timezone: input.timezone?.trim() || DEFAULT_TIMEZONE,
    lead_days: Math.max(0, Math.floor(input.lead_days ?? 0)),
    is_active: input.is_active ?? true,
  }
}

/**
 * A plan without checklists would generate empty maintenance orders, so at
 * least one published platform template is required to save.
 */
async function assertLinkableTemplates(templateIds: string[]): Promise<string[]> {
  const unique = [...new Set(templateIds.filter(Boolean))]
  if (unique.length === 0) {
    throw new Error('El pla necessita almenys una plantilla de checklist publicada.')
  }

  const linkable = await listPublishedPlatformTemplates()
  const linkableIds = new Set(linkable.map((t) => t.id))
  const invalid = unique.filter((id) => !linkableIds.has(id))
  if (invalid.length > 0) {
    throw new Error(
      'Alguna plantilla seleccionada no és de plataforma o no té versió publicada.',
    )
  }
  return unique
}

async function replacePlanChecklists(planId: string, templateIds: string[]): Promise<void> {
  const supabase = createSupabaseAdminClient()

  const { error: deleteError } = await supabase
    .from('maintenance_plan_checklists')
    .delete()
    .eq('plan_id', planId)
  if (deleteError) throw new Error(describeDbError(deleteError))

  const { error: insertError } = await supabase.from('maintenance_plan_checklists').insert(
    templateIds.map((templateId, index) => ({
      plan_id: planId,
      template_id: templateId,
      position: index,
    })),
  )
  if (insertError) throw new Error(describeDbError(insertError))
}

export async function createPlatformMaintenancePlan(
  input: MaintenancePlanInput,
): Promise<ActionResult & { planId?: string }> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  let payload: Record<string, unknown>
  let templateIds: string[]
  try {
    payload = buildPlanPayload(input)
    templateIds = await assertLinkableTemplates(input.templateIds)
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : String(err) }
  }

  const { data, error } = await supabase
    .from('maintenance_plans')
    .insert({ ...payload, tenant_id: null })
    .select('id')
    .single()
  if (error) return { ok: false, message: describeDbError(error) }

  const planId = str(asRecord(data).id)
  try {
    await replacePlanChecklists(planId, templateIds)
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : String(err) }
  }

  revalidatePath(PLANS_PATH)
  return { ok: true, message: 'Pla de plataforma creat', planId }
}

export async function updatePlatformMaintenancePlan(
  planId: string,
  input: MaintenancePlanInput,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  let payload: Record<string, unknown>
  let templateIds: string[]
  try {
    payload = buildPlanPayload(input)
    templateIds = await assertLinkableTemplates(input.templateIds)
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : String(err) }
  }

  const { error } = await supabase
    .from('maintenance_plans')
    .update(payload)
    .eq('id', planId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  try {
    await replacePlanChecklists(planId, templateIds)
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : String(err) }
  }

  revalidatePath(PLANS_PATH)
  return { ok: true, message: 'Pla de plataforma actualitzat' }
}

export async function setPlatformMaintenancePlanActive(
  planId: string,
  isActive: boolean,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  if (isActive) {
    const { count, error: countError } = await supabase
      .from('maintenance_plan_checklists')
      .select('id', { count: 'exact', head: true })
      .eq('plan_id', planId)
    if (countError) return { ok: false, message: describeDbError(countError) }
    if ((count ?? 0) === 0) {
      return { ok: false, message: 'No es pot activar un pla sense plantilles de checklist.' }
    }
  }

  const { error } = await supabase
    .from('maintenance_plans')
    .update({ is_active: isActive })
    .eq('id', planId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(PLANS_PATH)
  return { ok: true, message: isActive ? 'Pla activat' : 'Pla desactivat' }
}

/** Plans keep clone lineage (`maintenance_plan_forks`), so they are archived. */
export async function archivePlatformMaintenancePlan(planId: string): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase
    .from('maintenance_plans')
    .update({ is_archived: true, is_active: false })
    .eq('id', planId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(PLANS_PATH)
  return { ok: true, message: 'Pla arxivat' }
}

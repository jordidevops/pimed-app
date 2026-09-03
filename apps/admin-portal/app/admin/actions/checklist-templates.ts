'use server'

import { revalidatePath } from 'next/cache'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { assertBackofficeRole } from '@/lib/platform-catalog/server'
import {
  assertArchetype,
  assertKind,
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
  type ActionResult,
  type CatalogFilters,
  type ChecklistResponseType,
  type PagedResult,
} from '@/lib/platform-catalog/constants'

const TEMPLATES_PATH = '/dashboard/settings/checklist-templates'
const PLANS_PATH = '/dashboard/settings/maintenance-plans'

const TEMPLATE_COLUMNS =
  'id, name, description, kind, locale, category, vertical, archetype, is_active, is_archived, created_at, updated_at'
const ITEM_COLUMNS =
  'id, version_id, position, review_point_id, title, description_internal, description_public, locale, category, include_in_report, is_required, response_type, response_set_id, evidence_required'

export interface PlatformChecklistTemplate {
  id: string
  name: string
  description: string | null
  kind: string
  locale: string
  category: string
  vertical: string
  archetype: string
  is_active: boolean
  is_archived: boolean
  created_at: string | null
  updated_at: string | null
  draft_version_id: string | null
  draft_version_number: number | null
  draft_item_count: number
  published_version_id: string | null
  published_version_number: number | null
  published_item_count: number
}

export interface PlatformTemplateVersion {
  id: string
  template_id: string
  version_number: number
  status: 'draft' | 'published' | 'archived'
  default_response_set_id: string | null
  published_at: string | null
}

export interface PlatformTemplateItem {
  id: string
  version_id: string
  position: number
  review_point_id: string | null
  title: string
  description_internal: string | null
  description_public: string | null
  locale: string | null
  category: string | null
  include_in_report: boolean
  is_required: boolean
  response_type: string
  response_set_id: string | null
  evidence_required: boolean
}

export interface PlatformTemplateDependencies {
  /** Platform maintenance plans that link this template. */
  plans: Array<{ id: string; name: string }>
  /** Number of tenant templates forked from this one. */
  tenantForks: number
  /** Number of checklist runs created from any version of this template. */
  runs: number
}

export interface PlatformTemplateDetail {
  template: PlatformChecklistTemplate
  versions: PlatformTemplateVersion[]
  editingVersion: PlatformTemplateVersion | null
  items: PlatformTemplateItem[]
  dependencies: PlatformTemplateDependencies
}

export interface PlatformResponseSetOption {
  id: string
  name: string
  code: string | null
  locale: string
  option_count: number
  options: Array<{
    id: string
    label: string
    semantics: string
    position: number
    blocks_closeout: boolean
    requires_note: boolean
    color_token: string | null
  }>
}

export interface TemplateInput {
  name: string
  description?: string | null
  kind?: string
  locale?: string
  category?: string
  vertical?: string
  archetype?: string
  is_active?: boolean
}

export interface DraftItemInput {
  review_point_id?: string | null
  title?: string
  description_internal?: string | null
  description_public?: string | null
  include_in_report?: boolean
  is_required?: boolean
  response_type?: ChecklistResponseType
  response_set_id?: string | null
  evidence_required?: boolean
}

function mapVersion(raw: unknown): PlatformTemplateVersion {
  const row = asRecord(raw)
  return {
    id: str(row.id),
    template_id: str(row.template_id),
    version_number: num(row.version_number),
    status: (str(row.status, 'draft') as PlatformTemplateVersion['status']),
    default_response_set_id: nullableStr(row.default_response_set_id),
    published_at: nullableStr(row.published_at),
  }
}

function mapItem(raw: unknown): PlatformTemplateItem {
  const row = asRecord(raw)
  return {
    id: str(row.id),
    version_id: str(row.version_id),
    position: num(row.position),
    review_point_id: nullableStr(row.review_point_id),
    title: str(row.title),
    description_internal: nullableStr(row.description_internal),
    description_public: nullableStr(row.description_public),
    locale: nullableStr(row.locale),
    category: nullableStr(row.category),
    include_in_report: row.include_in_report === true,
    is_required: row.is_required === true,
    response_type: str(row.response_type, 'checkbox'),
    response_set_id: nullableStr(row.response_set_id),
    evidence_required: row.evidence_required === true,
  }
}

function mapTemplateBase(raw: unknown): Omit<
  PlatformChecklistTemplate,
  | 'draft_version_id'
  | 'draft_version_number'
  | 'draft_item_count'
  | 'published_version_id'
  | 'published_version_number'
  | 'published_item_count'
> {
  const row = asRecord(raw)
  return {
    id: str(row.id),
    name: str(row.name),
    description: nullableStr(row.description),
    kind: str(row.kind, 'todo'),
    locale: str(row.locale, 'ca'),
    category: str(row.category, 'general'),
    vertical: str(row.vertical, 'generic'),
    archetype: str(row.archetype, 'generic'),
    is_active: row.is_active !== false,
    is_archived: row.is_archived === true,
    created_at: nullableStr(row.created_at),
    updated_at: nullableStr(row.updated_at),
  }
}

/** Latest draft + latest published version of each template, with item counts. */
async function loadVersionSummaries(templateIds: string[]) {
  const summaries = new Map<
    string,
    {
      draft: PlatformTemplateVersion | null
      published: PlatformTemplateVersion | null
      itemCounts: Map<string, number>
    }
  >()
  if (templateIds.length === 0) return summaries

  const supabase = createSupabaseAdminClient()
  const { data: versionRows, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number, status, default_response_set_id, published_at')
    .in('template_id', templateIds)
    .order('version_number', { ascending: false })
  if (versionError) throw new Error(describeDbError(versionError))

  const versions = (versionRows ?? []).map(mapVersion)
  const relevantIds: string[] = []

  for (const templateId of templateIds) {
    const own = versions.filter((v) => v.template_id === templateId)
    const draft = own.find((v) => v.status === 'draft') ?? null
    const published = own.find((v) => v.status === 'published') ?? null
    if (draft) relevantIds.push(draft.id)
    if (published) relevantIds.push(published.id)
    summaries.set(templateId, { draft, published, itemCounts: new Map() })
  }

  if (relevantIds.length > 0) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('id, version_id')
      .in('version_id', relevantIds)
    if (itemError) throw new Error(describeDbError(itemError))

    const counts = new Map<string, number>()
    for (const raw of itemRows ?? []) {
      const versionId = str(asRecord(raw).version_id)
      counts.set(versionId, (counts.get(versionId) ?? 0) + 1)
    }
    for (const summary of summaries.values()) summary.itemCounts = counts
  }

  return summaries
}

export async function listPlatformChecklistTemplates(
  filters: CatalogFilters & { kind?: string } = {},
): Promise<PagedResult<PlatformChecklistTemplate>> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()
  const { page, size, from, to } = resolvePaging(filters.page, filters.pageSize)

  let query = supabase
    .from('checklist_templates')
    .select(TEMPLATE_COLUMNS, { count: 'exact' })
    .is('tenant_id', null)

  if (!filters.includeArchived) query = query.eq('is_archived', false)
  if (filters.kind) query = query.eq('kind', filters.kind)
  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category.toLowerCase())
  if (filters.vertical) query = query.eq('vertical', filters.vertical.toLowerCase())
  if (filters.archetype) query = query.eq('archetype', filters.archetype)

  const search = sanitizeSearch(filters.search)
  if (search) query = query.or(`name.ilike.%${search}%,description.ilike.%${search}%`)

  const { data, error, count } = await query.order('name', { ascending: true }).range(from, to)
  if (error) throw new Error(describeDbError(error))

  const bases = (data ?? []).map(mapTemplateBase)
  const summaries = await loadVersionSummaries(bases.map((b) => b.id))
  const total = count ?? bases.length

  const rows: PlatformChecklistTemplate[] = bases.map((base) => {
    const summary = summaries.get(base.id)
    const draft = summary?.draft ?? null
    const published = summary?.published ?? null
    return {
      ...base,
      draft_version_id: draft?.id ?? null,
      draft_version_number: draft?.version_number ?? null,
      draft_item_count: draft ? (summary?.itemCounts.get(draft.id) ?? 0) : 0,
      published_version_id: published?.id ?? null,
      published_version_number: published?.version_number ?? null,
      published_item_count: published ? (summary?.itemCounts.get(published.id) ?? 0) : 0,
    }
  })

  return { rows, total, page, pageSize: size, pageCount: pageCount(total, size) }
}

export async function getPlatformChecklistTemplate(
  templateId: string,
): Promise<PlatformTemplateDetail> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  const { data: templateRow, error: templateError } = await supabase
    .from('checklist_templates')
    .select(TEMPLATE_COLUMNS)
    .eq('id', templateId)
    .is('tenant_id', null)
    .single()
  if (templateError) throw new Error(describeDbError(templateError))

  const { data: versionRows, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number, status, default_response_set_id, published_at')
    .eq('template_id', templateId)
    .order('version_number', { ascending: false })
  if (versionError) throw new Error(describeDbError(versionError))

  const versions = (versionRows ?? []).map(mapVersion)
  const draft = versions.find((v) => v.status === 'draft') ?? null
  const published = versions.find((v) => v.status === 'published') ?? null
  const editingVersion = draft ?? published ?? versions[0] ?? null

  let items: PlatformTemplateItem[] = []
  if (editingVersion) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select(ITEM_COLUMNS)
      .eq('version_id', editingVersion.id)
      .order('position', { ascending: true })
    if (itemError) throw new Error(describeDbError(itemError))
    items = (itemRows ?? []).map(mapItem)
  }

  const { data: planLinks, error: planLinkError } = await supabase
    .from('maintenance_plan_checklists')
    .select('plan_id')
    .eq('template_id', templateId)
  if (planLinkError) throw new Error(describeDbError(planLinkError))

  const planIds = [...new Set((planLinks ?? []).map((raw) => str(asRecord(raw).plan_id)))]
  let plans: Array<{ id: string; name: string }> = []
  if (planIds.length > 0) {
    const { data: planRows, error: planError } = await supabase
      .from('maintenance_plans')
      .select('id, name')
      .in('id', planIds)
    if (planError) throw new Error(describeDbError(planError))
    plans = (planRows ?? []).map((raw) => {
      const row = asRecord(raw)
      return { id: str(row.id), name: str(row.name) }
    })
  }

  const { count: forkCount, error: forkError } = await supabase
    .from('checklist_template_forks')
    .select('id', { count: 'exact', head: true })
    .eq('source_template_id', templateId)
  if (forkError) throw new Error(describeDbError(forkError))

  const { count: runCount, error: runError } = await supabase
    .from('checklist_runs')
    .select('id', { count: 'exact', head: true })
    .eq('template_id', templateId)
  if (runError) throw new Error(describeDbError(runError))

  const base = mapTemplateBase(templateRow)
  const template: PlatformChecklistTemplate = {
    ...base,
    draft_version_id: draft?.id ?? null,
    draft_version_number: draft?.version_number ?? null,
    draft_item_count: draft && editingVersion?.id === draft.id ? items.length : 0,
    published_version_id: published?.id ?? null,
    published_version_number: published?.version_number ?? null,
    published_item_count: published && editingVersion?.id === published.id ? items.length : 0,
  }

  return {
    template,
    versions,
    editingVersion,
    items,
    dependencies: {
      plans,
      tenantForks: forkCount ?? 0,
      runs: runCount ?? 0,
    },
  }
}

/** Platform response sets available as the default answer scale of a version. */
export async function listPlatformResponseSets(): Promise<PlatformResponseSetOption[]> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  const { data: setRows, error: setError } = await supabase
    .from('checklist_response_sets')
    .select('id, name, code, locale')
    .is('tenant_id', null)
    .eq('is_active', true)
    .order('name', { ascending: true })
  if (setError) throw new Error(describeDbError(setError))

  const sets = (setRows ?? []).map(asRecord)
  if (sets.length === 0) return []

  const { data: optionRows, error: optionError } = await supabase
    .from('checklist_response_options')
    .select(
      'id, response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token',
    )
    .in(
      'response_set_id',
      sets.map((s) => str(s.id)),
    )
    .order('position', { ascending: true })
  if (optionError) throw new Error(describeDbError(optionError))

  const optionsBySet = new Map<
    string,
    PlatformResponseSetOption['options']
  >()
  for (const raw of optionRows ?? []) {
    const row = asRecord(raw)
    const setId = str(row.response_set_id)
    const list = optionsBySet.get(setId) ?? []
    list.push({
      id: str(row.id),
      label: str(row.label),
      semantics: str(row.semantics, 'info'),
      position: num(row.position, 0),
      blocks_closeout: row.blocks_closeout === true,
      requires_note: row.requires_note === true,
      color_token: nullableStr(row.color_token),
    })
    optionsBySet.set(setId, list)
  }

  return sets.map((set) => {
    const id = str(set.id)
    const options = optionsBySet.get(id) ?? []
    return {
      id,
      name: str(set.name),
      code: nullableStr(set.code),
      locale: str(set.locale, 'ca'),
      option_count: options.length,
      options,
    }
  })
}

function buildTemplatePayload(input: TemplateInput): Record<string, unknown> {
  const name = input.name.trim()
  if (!name) throw new Error('El nom de la plantilla és obligatori.')

  return {
    name,
    description: input.description?.trim() || null,
    kind: assertKind(input.kind),
    locale: assertLocale(input.locale),
    category: normalizeTaxonomy(input.category, 'general'),
    vertical: normalizeTaxonomy(input.vertical, 'generic'),
    archetype: assertArchetype(input.archetype),
    is_active: input.is_active ?? true,
  }
}

/** Creates the template plus its empty draft version 1. */
export async function createPlatformChecklistTemplate(
  input: TemplateInput,
): Promise<ActionResult & { templateId?: string }> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { data, error } = await supabase
    .from('checklist_templates')
    .insert({ ...buildTemplatePayload(input), tenant_id: null, is_default: false })
    .select('id')
    .single()
  if (error) return { ok: false, message: describeDbError(error) }

  const templateId = str(asRecord(data).id)
  const { error: versionError } = await supabase.from('checklist_template_versions').insert({
    template_id: templateId,
    version_number: 1,
    status: 'draft',
  })
  if (versionError) return { ok: false, message: describeDbError(versionError) }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Plantilla creada com a esborrany', templateId }
}

export async function updatePlatformChecklistTemplate(
  templateId: string,
  input: TemplateInput,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase
    .from('checklist_templates')
    .update(buildTemplatePayload(input))
    .eq('id', templateId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Plantilla actualitzada' }
}

export async function setPlatformTemplateDefaultResponseSet(
  versionId: string,
  responseSetId: string | null,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase
    .from('checklist_template_versions')
    .update({ default_response_set_id: responseSetId })
    .eq('id', versionId)
    .eq('status', 'draft')
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Conjunt de respostes per defecte desat' }
}

/**
 * Replaces the draft items in one shot. Review-point items inherit the live
 * catalog text so the NOT NULL title is satisfied before publication (publishing
 * re-freezes the text anyway).
 */
export async function savePlatformTemplateDraftItems(
  versionId: string,
  items: DraftItemInput[],
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { data: versionRow, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, status')
    .eq('id', versionId)
    .single()
  if (versionError) return { ok: false, message: describeDbError(versionError) }
  if (str(asRecord(versionRow).status) !== 'draft') {
    return { ok: false, message: 'Només es poden editar els punts d\'un esborrany.' }
  }

  const pointIds = [...new Set(items.map((i) => i.review_point_id).filter((id): id is string => !!id))]
  const pointsById = new Map<string, Record<string, unknown>>()
  if (pointIds.length > 0) {
    const { data: pointRows, error: pointError } = await supabase
      .from('checklist_review_points')
      .select('id, title, description, client_text, locale, category')
      .in('id', pointIds)
    if (pointError) return { ok: false, message: describeDbError(pointError) }
    for (const raw of pointRows ?? []) {
      const row = asRecord(raw)
      pointsById.set(str(row.id), row)
    }
  }

  const payload: Record<string, unknown>[] = []
  for (const [index, item] of items.entries()) {
    const point = item.review_point_id ? pointsById.get(item.review_point_id) : undefined
    if (item.review_point_id && !point) {
      return { ok: false, message: `Punt de revisió no trobat: ${item.review_point_id}` }
    }

    const title = point ? str(point.title) : (item.title ?? '').trim()
    if (!title) return { ok: false, message: `El punt #${index + 1} necessita un títol.` }

    // The schema only allows checkbox items without a linked review point.
    const responseType: ChecklistResponseType = point
      ? 'single_choice'
      : (item.response_type ?? 'checkbox')

    payload.push({
      version_id: versionId,
      position: index,
      review_point_id: item.review_point_id ?? null,
      title,
      description_internal: point
        ? nullableStr(point.description)
        : item.description_internal?.trim() || null,
      description_public: point
        ? (nullableStr(point.client_text) ?? nullableStr(point.description))
        : item.description_public?.trim() || null,
      locale: point ? str(point.locale, 'ca') : null,
      category: point ? str(point.category, 'general') : null,
      include_in_report: item.include_in_report ?? false,
      is_required: item.is_required ?? false,
      response_type: responseType,
      response_set_id: item.response_set_id ?? null,
      evidence_required: item.evidence_required ?? false,
    })
  }

  const { error: deleteError } = await supabase
    .from('checklist_template_items')
    .delete()
    .eq('version_id', versionId)
  if (deleteError) return { ok: false, message: describeDbError(deleteError) }

  if (payload.length > 0) {
    const { error: insertError } = await supabase.from('checklist_template_items').insert(payload)
    if (insertError) return { ok: false, message: describeDbError(insertError) }
  }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: `Esborrany desat (${payload.length} punts)` }
}

/** Opens a new draft from the published version, resyncing catalog text. */
export async function createPlatformTemplateDraft(templateId: string): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase.rpc('create_draft_from_published_checklist', {
    p_template_id: templateId,
  })
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Nou esborrany creat' }
}

export async function publishPlatformTemplateVersion(versionId: string): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { count, error: countError } = await supabase
    .from('checklist_template_items')
    .select('id', { count: 'exact', head: true })
    .eq('version_id', versionId)
  if (countError) return { ok: false, message: describeDbError(countError) }
  if ((count ?? 0) === 0) {
    return { ok: false, message: 'No es pot publicar una versió sense punts.' }
  }

  const { error } = await supabase.rpc('publish_checklist_template_version', {
    p_version_id: versionId,
  })
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(TEMPLATES_PATH)
  revalidatePath(PLANS_PATH)
  return { ok: true, message: 'Versió publicada' }
}

export async function setPlatformTemplateActive(
  templateId: string,
  isActive: boolean,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase
    .from('checklist_templates')
    .update({ is_active: isActive })
    .eq('id', templateId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: isActive ? 'Plantilla activada' : 'Plantilla desactivada' }
}

/**
 * Templates are never hard-deleted: runs and tenant forks point at them, and
 * plans reference them with ON DELETE RESTRICT.
 */
export async function archivePlatformChecklistTemplate(templateId: string): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { data: planLinks, error: planError } = await supabase
    .from('maintenance_plan_checklists')
    .select('plan_id')
    .eq('template_id', templateId)
    .limit(1)
  if (planError) return { ok: false, message: describeDbError(planError) }
  if ((planLinks ?? []).length > 0) {
    return {
      ok: false,
      message: 'Hi ha plans de manteniment que usen aquesta plantilla. Desvincula-la abans d\'arxivar-la.',
    }
  }

  const { error } = await supabase
    .from('checklist_templates')
    .update({ is_archived: true, is_active: false })
    .eq('id', templateId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Plantilla arxivada' }
}

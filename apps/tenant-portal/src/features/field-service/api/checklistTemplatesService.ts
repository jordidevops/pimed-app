import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import type { ChecklistLocale } from './checklistPointsService'

export type ProjectType = 'internal' | 'work_order' | 'maintenance'
export type ChecklistKind = 'todo' | 'review'
export type VisitIntent = 'inspection' | 'corrective' | 'generic'
export type ResponseType = 'checkbox' | 'single_choice'
export type VersionStatus = 'draft' | 'published' | 'archived'
export type RunStatus = 'pending' | 'in_progress' | 'completed' | 'superseded'
export type AnswerSemantic = 'pass' | 'warning' | 'fail' | 'na' | 'neutral'

export const CHECKLIST_KINDS: ChecklistKind[] = ['todo', 'review']
export const VISIT_INTENTS: VisitIntent[] = ['inspection', 'corrective', 'generic']
export const TEMPLATES_PAGE_SIZE = 20

export interface ChecklistTemplate {
  id: string
  tenant_id: string | null
  name: string
  description: string | null
  kind: ChecklistKind
  locale: ChecklistLocale
  category: string
  vertical: string
  archetype: string
  intent: VisitIntent
  metadata: Record<string, unknown>
  is_default: boolean
  is_active: boolean
  is_archived: boolean
  created_by: string | null
  created_at: string | null
  updated_at: string | null
}

export interface ChecklistTemplateVersion {
  id: string
  template_id: string
  version_number: number
  status: VersionStatus
  default_response_set_id: string | null
  published_at: string | null
  published_by: string | null
  created_by: string | null
  created_at: string | null
  updated_at: string | null
}

export interface ChecklistTemplateItem {
  id: string
  version_id: string
  position: number
  review_point_id: string | null
  title: string
  description_internal: string | null
  description_public: string | null
  locale: ChecklistLocale | null
  category: string | null
  include_in_report: boolean
  is_required: boolean
  response_type: ResponseType
  response_set_id: string | null
  evidence_required: boolean
  created_at: string | null
}

export interface ChecklistTemplateFork {
  id: string
  source_template_id: string
  source_version_id: string | null
  source_published_version_number: number | null
  tenant_template_id: string
  tenant_id: string
  created_at: string | null
}

export interface TemplateForkStatus {
  tenantTemplateId: string
  sourceTemplateId: string
  forkVersion: number | null
  sourceVersion: number | null
  updateAvailable: boolean
}

export interface ChecklistResponseSet {
  id: string
  tenant_id: string | null
  name: string
  code: string | null
  locale: ChecklistLocale
  category: string
  vertical: string
  is_active: boolean
  created_at: string | null
  updated_at: string | null
  options?: ChecklistResponseOption[]
}

export interface ChecklistResponseOption {
  id: string
  response_set_id: string
  label: string
  semantics: AnswerSemantic
  position: number
  blocks_closeout: boolean
  requires_note: boolean
  color_token: string | null
  created_at: string | null
}

export interface ChecklistRun {
  id: string
  tenant_id: string
  project_id: string
  template_id: string
  template_version_id: string
  name_snapshot: string
  version_number: number
  status: RunStatus
  supersedes_run_id: string | null
  sort_order: number
  started_at: string | null
  completed_at: string | null
  started_by: string | null
  completed_by: string | null
  public_report_payload: Json | null
  created_at: string | null
  updated_at: string | null
  items?: ChecklistRunItem[]
}

export type ResolutionStatus =
  | 'open'
  | 'resolved_same_visit'
  | 'deferred'
  | 'closed_unresolved'

export interface ChecklistRunItem {
  id: string
  tenant_id: string
  run_id: string
  template_item_id: string | null
  review_point_id: string | null
  position: number
  title: string
  description_internal: string | null
  description_public: string | null
  locale: ChecklistLocale | null
  category: string | null
  include_in_report: boolean
  is_required: boolean
  response_type: ResponseType
  response_set_id: string | null
  evidence_required: boolean
  value_bool: boolean | null
  value_option_id: string | null
  value_number: number | null
  value_text: string | null
  note: string | null
  answer_label: string | null
  answer_color_token: string | null
  answer_semantic: AnswerSemantic | null
  answer_blocks_closeout: boolean | null
  resolution_status: ResolutionStatus | null
  resolution_reason: string | null
  resolution_note: string | null
  resolved_at: string | null
  resolved_by: string | null
  client_mutation_id: string | null
  answered_at: string | null
  answered_by: string | null
  created_at: string | null
  updated_at: string | null
}

export interface TemplateDetail {
  template: ChecklistTemplate
  versions: ChecklistTemplateVersion[]
  items: ChecklistTemplateItem[]
  editingVersion: ChecklistTemplateVersion | null
  fork: ChecklistTemplateFork | null
  updateAvailable: boolean
}

export interface PlatformTemplatePreview {
  template: ChecklistTemplate
  version: ChecklistTemplateVersion | null
  items: ChecklistTemplateItem[]
}

export interface CloseoutBlocker {
  run_id: string
  run_name: string
  item_id: string
  title: string
  reason:
    | 'required_empty'
    | 'blocking_fail'
    | 'open_fail'
    | 'missing_note'
    | 'missing_resolution_note'
    | 'deferred_without_task'
}

export interface PublishedTemplateOption extends ChecklistTemplate {
  publishedVersion: ChecklistTemplateVersion
}

export interface TemplateFilters {
  q?: string
  locale?: string
  category?: string
  kind?: ChecklistKind
  limit?: number
  offset?: number
}

export interface PagedTemplates {
  rows: ChecklistTemplate[]
  total: number
}

/** Ítem d'esborrany tal com el manipula l'editor (encara sense id ni versió). */
export type DraftItemInput = {
  position?: number
  review_point_id?: string | null
  title: string
  description_internal?: string | null
  description_public?: string | null
  locale?: ChecklistLocale | null
  category?: string | null
  include_in_report?: boolean
  is_required?: boolean
  response_type?: ResponseType
  response_set_id?: string | null
  evidence_required?: boolean
}

function sanitizeSearch(q: string): string {
  return q.replace(/[,()*\\]/g, ' ').trim()
}

function mapTemplate(row: Record<string, unknown>): ChecklistTemplate {
  return {
    id: String(row.id),
    tenant_id: row.tenant_id != null ? String(row.tenant_id) : null,
    name: String(row.name ?? ''),
    description: row.description != null ? String(row.description) : null,
    kind: (row.kind as ChecklistKind) ?? 'todo',
    locale: (row.locale as ChecklistLocale) ?? 'ca',
    category: String(row.category ?? 'general'),
    vertical: String(row.vertical ?? 'generic'),
    archetype: String(row.archetype ?? 'generic'),
    intent: (row.intent as VisitIntent) ?? 'generic',
    metadata: (row.metadata as Record<string, unknown>) ?? {},
    is_default: row.is_default === true,
    is_active: row.is_active !== false,
    is_archived: row.is_archived === true,
    created_by: row.created_by != null ? String(row.created_by) : null,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapVersion(row: Record<string, unknown>): ChecklistTemplateVersion {
  return {
    id: String(row.id),
    template_id: String(row.template_id),
    version_number: Number(row.version_number ?? 0),
    status: (row.status as VersionStatus) ?? 'draft',
    default_response_set_id:
      row.default_response_set_id != null ? String(row.default_response_set_id) : null,
    published_at: (row.published_at as string | null) ?? null,
    published_by: row.published_by != null ? String(row.published_by) : null,
    created_by: row.created_by != null ? String(row.created_by) : null,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapTemplateItem(row: Record<string, unknown>): ChecklistTemplateItem {
  return {
    id: String(row.id),
    version_id: String(row.version_id),
    position: Number(row.position ?? 0),
    review_point_id: row.review_point_id != null ? String(row.review_point_id) : null,
    title: String(row.title ?? ''),
    description_internal: row.description_internal != null ? String(row.description_internal) : null,
    description_public: row.description_public != null ? String(row.description_public) : null,
    locale: (row.locale as ChecklistLocale | null) ?? null,
    category: row.category != null ? String(row.category) : null,
    include_in_report: row.include_in_report === true,
    is_required: row.is_required === true,
    response_type: (row.response_type as ResponseType) ?? 'checkbox',
    response_set_id: row.response_set_id != null ? String(row.response_set_id) : null,
    evidence_required: row.evidence_required === true,
    created_at: (row.created_at as string | null) ?? null,
  }
}

function mapFork(row: Record<string, unknown>): ChecklistTemplateFork {
  return {
    id: String(row.id),
    source_template_id: String(row.source_template_id),
    source_version_id: row.source_version_id != null ? String(row.source_version_id) : null,
    source_published_version_number:
      row.source_published_version_number != null
        ? Number(row.source_published_version_number)
        : null,
    tenant_template_id: String(row.tenant_template_id),
    tenant_id: String(row.tenant_id),
    created_at: (row.created_at as string | null) ?? null,
  }
}

function mapResponseSet(row: Record<string, unknown>): ChecklistResponseSet {
  return {
    id: String(row.id),
    tenant_id: row.tenant_id != null ? String(row.tenant_id) : null,
    name: String(row.name ?? ''),
    code: row.code != null ? String(row.code) : null,
    locale: (row.locale as ChecklistLocale) ?? 'ca',
    category: String(row.category ?? 'general'),
    vertical: String(row.vertical ?? 'generic'),
    is_active: row.is_active !== false,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapResponseOption(row: Record<string, unknown>): ChecklistResponseOption {
  return {
    id: String(row.id),
    response_set_id: String(row.response_set_id),
    label: String(row.label ?? ''),
    semantics: (row.semantics as AnswerSemantic) ?? 'neutral',
    position: Number(row.position ?? 0),
    blocks_closeout: row.blocks_closeout === true,
    requires_note: row.requires_note === true,
    color_token: row.color_token != null ? String(row.color_token) : null,
    created_at: (row.created_at as string | null) ?? null,
  }
}

function mapRun(row: Record<string, unknown>): ChecklistRun {
  return {
    id: String(row.id),
    tenant_id: String(row.tenant_id),
    project_id: String(row.project_id),
    template_id: String(row.template_id),
    template_version_id: String(row.template_version_id),
    name_snapshot: String(row.name_snapshot ?? ''),
    version_number: Number(row.version_number ?? 0),
    status: (row.status as RunStatus) ?? 'pending',
    supersedes_run_id: row.supersedes_run_id != null ? String(row.supersedes_run_id) : null,
    sort_order: Number(row.sort_order ?? 0),
    started_at: (row.started_at as string | null) ?? null,
    completed_at: (row.completed_at as string | null) ?? null,
    started_by: row.started_by != null ? String(row.started_by) : null,
    completed_by: row.completed_by != null ? String(row.completed_by) : null,
    public_report_payload: (row.public_report_payload as Json | null) ?? null,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapRunItem(row: Record<string, unknown>): ChecklistRunItem {
  return {
    id: String(row.id),
    tenant_id: String(row.tenant_id),
    run_id: String(row.run_id),
    template_item_id: row.template_item_id != null ? String(row.template_item_id) : null,
    review_point_id: row.review_point_id != null ? String(row.review_point_id) : null,
    position: Number(row.position ?? 0),
    title: String(row.title ?? ''),
    description_internal: row.description_internal != null ? String(row.description_internal) : null,
    description_public: row.description_public != null ? String(row.description_public) : null,
    locale: (row.locale as ChecklistLocale | null) ?? null,
    category: row.category != null ? String(row.category) : null,
    include_in_report: row.include_in_report === true,
    is_required: row.is_required === true,
    response_type: (row.response_type as ResponseType) ?? 'checkbox',
    response_set_id: row.response_set_id != null ? String(row.response_set_id) : null,
    evidence_required: row.evidence_required === true,
    value_bool: row.value_bool != null ? Boolean(row.value_bool) : null,
    value_option_id: row.value_option_id != null ? String(row.value_option_id) : null,
    value_number: row.value_number != null ? Number(row.value_number) : null,
    value_text: row.value_text != null ? String(row.value_text) : null,
    note: row.note != null ? String(row.note) : null,
    answer_label: row.answer_label != null ? String(row.answer_label) : null,
    answer_color_token: row.answer_color_token != null ? String(row.answer_color_token) : null,
    answer_semantic: (row.answer_semantic as AnswerSemantic | null) ?? null,
    answer_blocks_closeout:
      row.answer_blocks_closeout != null ? Boolean(row.answer_blocks_closeout) : null,
    resolution_status: (row.resolution_status as ResolutionStatus | null) ?? null,
    resolution_reason: row.resolution_reason != null ? String(row.resolution_reason) : null,
    resolution_note: row.resolution_note != null ? String(row.resolution_note) : null,
    resolved_at: (row.resolved_at as string | null) ?? null,
    resolved_by: row.resolved_by != null ? String(row.resolved_by) : null,
    client_mutation_id: row.client_mutation_id != null ? String(row.client_mutation_id) : null,
    answered_at: (row.answered_at as string | null) ?? null,
    answered_by: row.answered_by != null ? String(row.answered_by) : null,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

// ---------------------------------------------------------------------------
// Plantilles del tenant
// ---------------------------------------------------------------------------

export async function listChecklistTemplates(tenantId: string): Promise<ChecklistTemplate[]> {
  const { data, error } = await supabase
    .from('checklist_templates')
    .select('*')
    .eq('tenant_id', tenantId)
    .eq('is_archived', false)
    .order('name', { ascending: true })

  if (error) throw error
  return ((data ?? []) as unknown as Record<string, unknown>[]).map(mapTemplate)
}

export async function listPlatformTemplates(
  filters: TemplateFilters = {},
): Promise<PagedTemplates> {
  const limit = filters.limit ?? TEMPLATES_PAGE_SIZE
  const offset = filters.offset ?? 0

  let query = supabase
    .from('checklist_templates')
    .select('*', { count: 'exact' })
    .is('tenant_id', null)
    .eq('is_archived', false)
    .eq('is_active', true)

  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category)
  if (filters.kind) query = query.eq('kind', filters.kind)

  const search = sanitizeSearch(filters.q ?? '')
  if (search) {
    query = query.or(`name.ilike.%${search}%,description.ilike.%${search}%`)
  }

  const { data, error, count } = await query
    .order('name', { ascending: true })
    .range(offset, offset + limit - 1)

  if (error) throw error
  return {
    rows: ((data ?? []) as unknown as Record<string, unknown>[]).map(mapTemplate),
    total: count ?? 0,
  }
}

export async function listTemplateCategories(tenantId: string | null): Promise<string[]> {
  let query = supabase.from('checklist_templates').select('category')
  query = tenantId ? query.eq('tenant_id', tenantId) : query.is('tenant_id', null)

  const { data, error } = await query.eq('is_archived', false).limit(500)
  if (error) throw error

  const categories = new Set<string>()
  for (const raw of (data ?? []) as unknown as Record<string, unknown>[]) {
    const category = String(raw.category ?? '').trim()
    if (category) categories.add(category)
  }
  return [...categories].sort((a, b) => a.localeCompare(b))
}

async function getTemplateFork(templateId: string): Promise<ChecklistTemplateFork | null> {
  const { data, error } = await supabase
    .from('checklist_template_forks')
    .select('*')
    .eq('tenant_template_id', templateId)
    .maybeSingle()
  if (error) throw error
  return data ? mapFork(data as unknown as Record<string, unknown>) : null
}

async function latestPublishedVersionNumber(templateId: string): Promise<number | null> {
  const { data, error } = await supabase
    .from('checklist_template_versions')
    .select('version_number')
    .eq('template_id', templateId)
    .eq('status', 'published')
    .order('version_number', { ascending: false })
    .limit(1)
  if (error) throw error
  const rows = (data ?? []) as unknown as Record<string, unknown>[]
  return rows.length > 0 ? Number(rows[0].version_number ?? 0) : null
}

export async function getTemplateDetail(templateId: string): Promise<TemplateDetail> {
  const { data: templateRow, error: tplError } = await supabase
    .from('checklist_templates')
    .select('*')
    .eq('id', templateId)
    .single()
  if (tplError) throw tplError

  const { data: versionRows, error: verError } = await supabase
    .from('checklist_template_versions')
    .select('*')
    .eq('template_id', templateId)
    .order('version_number', { ascending: false })
  if (verError) throw verError

  const versions = ((versionRows ?? []) as unknown as Record<string, unknown>[]).map(mapVersion)
  const editingVersion =
    versions.find((v) => v.status === 'draft')
    ?? versions.find((v) => v.status === 'published')
    ?? versions[0]
    ?? null

  let items: ChecklistTemplateItem[] = []
  if (editingVersion) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('*')
      .eq('version_id', editingVersion.id)
      .order('position', { ascending: true })
    if (itemError) throw itemError
    items = ((itemRows ?? []) as unknown as Record<string, unknown>[]).map(mapTemplateItem)
  }

  const fork = await getTemplateFork(templateId)
  let updateAvailable = false
  if (fork) {
    const sourceVersion = await latestPublishedVersionNumber(fork.source_template_id)
    updateAvailable =
      sourceVersion != null
      && (fork.source_published_version_number == null
        || fork.source_published_version_number < sourceVersion)
  }

  return {
    template: mapTemplate(templateRow as unknown as Record<string, unknown>),
    versions,
    items,
    editingVersion,
    fork,
    updateAvailable,
  }
}

/** Contingut d'una plantilla de plataforma, per previsualitzar-la abans de clonar. */
export async function getPlatformTemplatePreview(
  templateId: string,
): Promise<PlatformTemplatePreview> {
  const { data: templateRow, error: tplError } = await supabase
    .from('checklist_templates')
    .select('*')
    .eq('id', templateId)
    .single()
  if (tplError) throw tplError

  const { data: versionRows, error: verError } = await supabase
    .from('checklist_template_versions')
    .select('*')
    .eq('template_id', templateId)
    .order('version_number', { ascending: false })
  if (verError) throw verError

  const versions = ((versionRows ?? []) as unknown as Record<string, unknown>[]).map(mapVersion)
  const version = versions.find((v) => v.status === 'published') ?? versions[0] ?? null

  let items: ChecklistTemplateItem[] = []
  if (version) {
    const { data: itemRows, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('*')
      .eq('version_id', version.id)
      .order('position', { ascending: true })
    if (itemError) throw itemError
    items = ((itemRows ?? []) as unknown as Record<string, unknown>[]).map(mapTemplateItem)
  }

  return { template: mapTemplate(templateRow as unknown as Record<string, unknown>), version, items }
}

/** Plantilles clonades del tenant amb actualització pendent respecte l'origen. */
export async function listTemplateForkStatus(
  tenantId: string,
): Promise<Map<string, TemplateForkStatus>> {
  const { data, error } = await supabase
    .from('checklist_template_forks')
    .select('*')
    .eq('tenant_id', tenantId)
  if (error) throw error

  const forks = ((data ?? []) as unknown as Record<string, unknown>[]).map(mapFork)
  const result = new Map<string, TemplateForkStatus>()
  if (forks.length === 0) return result

  const sourceIds = [...new Set(forks.map((f) => f.source_template_id))]
  const { data: versionRows, error: verError } = await supabase
    .from('checklist_template_versions')
    .select('template_id, version_number, status')
    .in('template_id', sourceIds)
    .eq('status', 'published')
  if (verError) throw verError

  const latestByTemplate = new Map<string, number>()
  for (const raw of (versionRows ?? []) as unknown as Record<string, unknown>[]) {
    const templateId = String(raw.template_id)
    const versionNumber = Number(raw.version_number ?? 0)
    if (versionNumber > (latestByTemplate.get(templateId) ?? 0)) {
      latestByTemplate.set(templateId, versionNumber)
    }
  }

  for (const fork of forks) {
    const sourceVersion = latestByTemplate.get(fork.source_template_id) ?? null
    result.set(fork.tenant_template_id, {
      tenantTemplateId: fork.tenant_template_id,
      sourceTemplateId: fork.source_template_id,
      forkVersion: fork.source_published_version_number,
      sourceVersion,
      updateAvailable:
        sourceVersion != null
        && (fork.source_published_version_number == null
          || fork.source_published_version_number < sourceVersion),
    })
  }
  return result
}

export async function createTemplate(params: {
  tenant_id: string
  name: string
  description?: string | null
  kind?: ChecklistKind
  locale?: ChecklistLocale
  category?: string | null
  intent?: VisitIntent
  is_default?: boolean
}): Promise<string> {
  const { data: template, error: tplError } = await supabase
    .from('checklist_templates')
    .insert({
      tenant_id: params.tenant_id,
      name: params.name.trim(),
      description: params.description?.trim() || null,
      kind: params.kind ?? 'todo',
      locale: params.locale ?? 'ca',
      category: params.category?.trim() || 'general',
      intent: params.intent ?? 'generic',
      is_active: true,
      is_archived: false,
    })
    .select('id')
    .single()
  if (tplError) throw tplError

  const templateId = String((template as unknown as { id: string }).id)
  const { error: verError } = await supabase
    .from('checklist_template_versions')
    .insert({ template_id: templateId, version_number: 1, status: 'draft' })
  if (verError) throw verError

  // `is_default` és exclusiu per tenant i kind: sempre via RPC.
  if (params.is_default) await setTemplateDefault(templateId, true)

  return templateId
}

export async function updateTemplate(
  templateId: string,
  patch: {
    name?: string
    description?: string | null
    kind?: ChecklistKind
    locale?: ChecklistLocale
    category?: string | null
    intent?: VisitIntent
    is_active?: boolean
  },
): Promise<void> {
  const payload: Record<string, unknown> = {}
  if (patch.name !== undefined) payload.name = patch.name.trim()
  if (patch.description !== undefined) payload.description = patch.description?.trim() || null
  if (patch.kind !== undefined) payload.kind = patch.kind
  if (patch.locale !== undefined) payload.locale = patch.locale
  if (patch.category !== undefined) payload.category = patch.category?.trim() || 'general'
  if (patch.intent !== undefined) payload.intent = patch.intent
  if (patch.is_active !== undefined) payload.is_active = patch.is_active
  if (Object.keys(payload).length === 0) return

  const { error } = await supabase
    .from('checklist_templates')
    .update(payload)
    .eq('id', templateId)
  if (error) throw error
}

export async function archiveTemplate(templateId: string): Promise<void> {
  const { error } = await supabase
    .from('checklist_templates')
    .update({ is_archived: true, is_active: false, is_default: false })
    .eq('id', templateId)
  if (error) throw error
}

export async function setTemplateDefault(
  templateId: string,
  isDefault: boolean,
): Promise<void> {
  const { error } = await supabase.rpc('set_checklist_template_default', {
    p_template_id: templateId,
    p_is_default: isDefault,
  })
  if (error) throw error
}

export async function setVersionDefaultResponseSet(
  versionId: string,
  responseSetId: string | null,
): Promise<void> {
  const { error } = await supabase
    .from('checklist_template_versions')
    .update({ default_response_set_id: responseSetId })
    .eq('id', versionId)
  if (error) throw error
}

export class ChecklistValidationError extends Error {
  constructor(public readonly code: string) {
    super(code)
    this.name = 'ChecklistValidationError'
  }
}

/**
 * Valida les restriccions de `kind` abans d'escriure:
 *  - `todo`   → ítems inline amb resposta de casella
 *  - `review` → ítems ancorats a un punt del catàleg amb opció única
 */
export function validateDraftItems(kind: ChecklistKind, items: DraftItemInput[]): void {
  const usable = items.filter((i) => i.title.trim())
  if (usable.length === 0) throw new ChecklistValidationError('items_required')

  for (const item of usable) {
    if (kind === 'todo') {
      if (item.review_point_id) throw new ChecklistValidationError('todo_item_cannot_have_point')
      if (item.response_type && item.response_type !== 'checkbox') {
        throw new ChecklistValidationError('todo_item_must_be_checkbox')
      }
    } else {
      if (!item.review_point_id) throw new ChecklistValidationError('review_item_requires_point')
      if (item.response_type && item.response_type !== 'single_choice') {
        throw new ChecklistValidationError('review_item_must_be_single_choice')
      }
    }
  }
}

/** Substitueix tots els ítems d'un esborrany de forma atòmica (RPC). */
export async function saveDraftItems(
  versionId: string,
  kind: ChecklistKind,
  items: DraftItemInput[],
): Promise<void> {
  validateDraftItems(kind, items)

  const payload = items
    .filter((i) => i.title.trim() || (kind === 'review' && i.review_point_id))
    .map((item) => ({
      review_point_id: kind === 'review' ? item.review_point_id ?? null : null,
      title: item.title.trim(),
      description_internal: item.description_internal?.trim() || null,
      description_public: item.description_public?.trim() || null,
      locale: item.locale ?? null,
      category: item.category ?? null,
      include_in_report: item.include_in_report === true,
      is_required: item.is_required === true,
      response_set_id: kind === 'review' ? item.response_set_id ?? null : null,
      evidence_required: item.evidence_required === true,
    }))

  const { error } = await supabase.rpc('save_draft_checklist_items', {
    p_version_id: versionId,
    p_items: payload as unknown as Json,
  })
  if (error) throw error
}

export async function publishVersion(versionId: string): Promise<string> {
  const { data, error } = await supabase.rpc('publish_checklist_template_version', {
    p_version_id: versionId,
  })
  if (error) throw error
  return String(data)
}

export async function createDraftFromPublished(templateId: string): Promise<string> {
  const { data, error } = await supabase.rpc('create_draft_from_published_checklist', {
    p_template_id: templateId,
  })
  if (error) throw error
  return String(data)
}

/** Refresca el text dels ítems d'un esborrany des del catàleg de punts. */
export async function syncDraftItemsFromPoints(versionId: string): Promise<number> {
  const { data, error } = await supabase.rpc('sync_draft_checklist_items_from_points', {
    p_version_id: versionId,
  })
  if (error) throw error
  return Number(data ?? 0)
}

export async function cloneTemplate(
  sourceId: string,
  tenantId: string,
  name?: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('clone_checklist_template', {
    p_source_template_id: sourceId,
    p_tenant_id: tenantId,
    p_name: name?.trim() || undefined,
  })
  if (error) throw error
  return String(data)
}

// ---------------------------------------------------------------------------
// Response sets
// ---------------------------------------------------------------------------

export async function listResponseSets(tenantId: string): Promise<ChecklistResponseSet[]> {
  const { data, error } = await supabase
    .from('checklist_response_sets')
    .select(`
      *,
      options:checklist_response_options(*)
    `)
    .or(`tenant_id.eq.${tenantId},tenant_id.is.null`)
    .eq('is_active', true)
    .order('name', { ascending: true })

  if (error) throw error

  return ((data ?? []) as unknown as Record<string, unknown>[]).map((row) => {
    const set = mapResponseSet(row)
    const options = ((row.options as unknown[]) ?? [])
      .map((o) => mapResponseOption(o as Record<string, unknown>))
      .sort((a, b) => a.position - b.position)
    return { ...set, options }
  })
}

/** Només conjunts de plataforma (per previsualitzar plantilles de biblioteca). */
export async function listPlatformResponseSets(): Promise<ChecklistResponseSet[]> {
  const { data, error } = await supabase
    .from('checklist_response_sets')
    .select(`
      *,
      options:checklist_response_options(*)
    `)
    .is('tenant_id', null)
    .eq('is_active', true)
    .order('name', { ascending: true })

  if (error) throw error

  return ((data ?? []) as unknown as Record<string, unknown>[]).map((row) => {
    const set = mapResponseSet(row)
    const options = ((row.options as unknown[]) ?? [])
      .map((o) => mapResponseOption(o as Record<string, unknown>))
      .sort((a, b) => a.position - b.position)
    return { ...set, options }
  })
}

export interface ResponseOptionInput {
  id?: string | null
  label: string
  semantics: AnswerSemantic
  position?: number
  blocks_closeout?: boolean
  requires_note?: boolean
  color_token?: string | null
}

export interface ResponseSetWriteInput {
  name: string
  code?: string | null
  locale?: ChecklistLocale
  category?: string
  vertical?: string
  is_active?: boolean
  options: ResponseOptionInput[]
}

async function optionIdsLocked(optionIds: string[]): Promise<Set<string>> {
  const locked = new Set<string>()
  if (optionIds.length === 0) return locked
  const { data, error } = await supabase
    .from('checklist_run_items')
    .select('value_option_id')
    .in('value_option_id', optionIds)
  if (error) throw error
  for (const row of data ?? []) {
    const id = (row as { value_option_id: string | null }).value_option_id
    if (id) locked.add(id)
  }
  return locked
}

async function setIdsPublishedLocked(setIds: string[]): Promise<Set<string>> {
  const locked = new Set<string>()
  if (setIds.length === 0) return locked

  const { data: versions, error: vErr } = await supabase
    .from('checklist_template_versions')
    .select('id, default_response_set_id')
    .eq('status', 'published')
    .in('default_response_set_id', setIds)
  if (vErr) throw vErr
  for (const row of versions ?? []) {
    const id = (row as { default_response_set_id: string | null }).default_response_set_id
    if (id) locked.add(id)
  }

  const { data: published, error: pErr } = await supabase
    .from('checklist_template_versions')
    .select('id')
    .eq('status', 'published')
  if (pErr) throw pErr
  const pubIds = (published ?? []).map((r) => String((r as { id: string }).id))
  if (pubIds.length > 0) {
    const { data: items, error: iErr } = await supabase
      .from('checklist_template_items')
      .select('response_set_id')
      .in('version_id', pubIds)
      .in('response_set_id', setIds)
    if (iErr) throw iErr
    for (const row of items ?? []) {
      const id = (row as { response_set_id: string | null }).response_set_id
      if (id) locked.add(id)
    }
  }
  return locked
}

export type TenantResponseSetDetail = ChecklistResponseSet & {
  published_locked: boolean
  options: Array<ChecklistResponseOption & { locked: boolean }>
}

export async function listTenantResponseSetsDetailed(
  tenantId: string,
  includeInactive = false,
): Promise<TenantResponseSetDetail[]> {
  let query = supabase
    .from('checklist_response_sets')
    .select(`*, options:checklist_response_options(*)`)
    .eq('tenant_id', tenantId)
    .order('name', { ascending: true })
  if (!includeInactive) query = query.eq('is_active', true)

  const { data, error } = await query
  if (error) throw error

  const rows = (data ?? []) as unknown as Record<string, unknown>[]
  const setIds = rows.map((r) => String(r.id))
  const allOptionIds = rows.flatMap((r) =>
    ((r.options as unknown[]) ?? []).map((o) => String((o as Record<string, unknown>).id)),
  )
  const [optLocked, setLocked] = await Promise.all([
    optionIdsLocked(allOptionIds),
    setIdsPublishedLocked(setIds),
  ])

  return rows.map((row) => {
    const set = mapResponseSet(row)
    const published_locked = setLocked.has(set.id)
    const options = ((row.options as unknown[]) ?? [])
      .map((o) => {
        const opt = mapResponseOption(o as Record<string, unknown>)
        return { ...opt, locked: optLocked.has(opt.id) || published_locked }
      })
      .sort((a, b) => a.position - b.position)
    return { ...set, options, published_locked }
  })
}

export async function createTenantResponseSet(
  tenantId: string,
  input: ResponseSetWriteInput,
): Promise<string> {
  if (!input.options.length) throw new Error('need_options')
  const { data, error } = await supabase
    .from('checklist_response_sets')
    .insert({
      tenant_id: tenantId,
      name: input.name.trim(),
      code: input.code?.trim() || null,
      locale: input.locale ?? 'ca',
      category: (input.category ?? 'general').trim().toLowerCase() || 'general',
      vertical: (input.vertical ?? 'generic').trim().toLowerCase() || 'generic',
      is_active: input.is_active ?? true,
    })
    .select('id')
    .single()
  if (error) throw error
  const setId = String((data as { id: string }).id)

  const { error: optError } = await supabase.from('checklist_response_options').insert(
    input.options.map((opt, index) => ({
      response_set_id: setId,
      label: opt.label.trim(),
      semantics: opt.semantics,
      position: index,
      blocks_closeout: opt.blocks_closeout === true,
      requires_note: opt.requires_note === true,
      color_token: opt.color_token ?? null,
    })),
  )
  if (optError) {
    await supabase.from('checklist_response_sets').delete().eq('id', setId)
    throw optError
  }
  return setId
}

export async function updateTenantResponseSet(
  tenantId: string,
  setId: string,
  input: ResponseSetWriteInput,
): Promise<void> {
  const detailed = (await listTenantResponseSetsDetailed(tenantId, true)).find((s) => s.id === setId)
  if (!detailed) throw new Error('set_not_found')
  if (!input.options.length) throw new Error('need_options')

  const { error: setError } = await supabase
    .from('checklist_response_sets')
    .update({
      name: input.name.trim(),
      code: input.code?.trim() || null,
      locale: input.locale ?? detailed.locale,
      category: (input.category ?? detailed.category).trim().toLowerCase() || 'general',
      vertical: (input.vertical ?? detailed.vertical).trim().toLowerCase() || 'generic',
      is_active: input.is_active ?? detailed.is_active,
    })
    .eq('id', setId)
    .eq('tenant_id', tenantId)
  if (setError) throw setError

  const kept = new Set<string>()
  for (const [index, opt] of input.options.entries()) {
    const existing = opt.id ? detailed.options.find((o) => o.id === opt.id) : undefined
    if (existing?.locked) {
      const { error } = await supabase
        .from('checklist_response_options')
        .update({ position: index })
        .eq('id', existing.id)
        .eq('response_set_id', setId)
      if (error) throw error
      kept.add(existing.id)
      continue
    }
    if (opt.id) {
      const { error } = await supabase
        .from('checklist_response_options')
        .update({
          label: opt.label.trim(),
          semantics: opt.semantics,
          blocks_closeout: opt.blocks_closeout === true,
          requires_note: opt.requires_note === true,
          color_token: opt.color_token ?? null,
          position: index,
        })
        .eq('id', opt.id)
        .eq('response_set_id', setId)
      if (error) throw error
      kept.add(opt.id)
    } else {
      const { data, error } = await supabase
        .from('checklist_response_options')
        .insert({
          response_set_id: setId,
          label: opt.label.trim(),
          semantics: opt.semantics,
          position: index,
          blocks_closeout: opt.blocks_closeout === true,
          requires_note: opt.requires_note === true,
          color_token: opt.color_token ?? null,
        })
        .select('id')
        .single()
      if (error) throw error
      kept.add(String((data as { id: string }).id))
    }
  }

  for (const old of detailed.options) {
    if (kept.has(old.id)) continue
    if (old.locked) throw new Error('option_locked')
    const { error } = await supabase
      .from('checklist_response_options')
      .delete()
      .eq('id', old.id)
      .eq('response_set_id', setId)
    if (error) throw error
  }
}

export async function setTenantResponseSetActive(
  tenantId: string,
  setId: string,
  isActive: boolean,
): Promise<void> {
  const { error } = await supabase
    .from('checklist_response_sets')
    .update({ is_active: isActive })
    .eq('id', setId)
    .eq('tenant_id', tenantId)
  if (error) throw error
}

export async function clonePlatformResponseSet(
  sourceSetId: string,
  tenantId: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('clone_checklist_response_set', {
    p_source_set_id: sourceSetId,
    p_tenant_id: tenantId,
  })
  if (error) throw error
  return String(data)
}

// ---------------------------------------------------------------------------
// Aplicació i execució
// ---------------------------------------------------------------------------

/**
 * Plantilles publicades del tenant. Les de plataforma no s'inclouen mai:
 * `api.apply_checklist_to_project` les rebutja i cal clonar-les abans.
 */
export async function listPublishedTemplatesForTenant(
  tenantId: string,
): Promise<PublishedTemplateOption[]> {
  const { data, error } = await supabase
    .from('checklist_templates')
    .select(`
      *,
      versions:checklist_template_versions(*)
    `)
    .eq('tenant_id', tenantId)
    .eq('is_active', true)
    .eq('is_archived', false)

  if (error) throw error

  const results: PublishedTemplateOption[] = []
  for (const row of (data ?? []) as unknown as Record<string, unknown>[]) {
    const template = mapTemplate(row)
    const published = ((row.versions as unknown[]) ?? [])
      .map((v) => mapVersion(v as Record<string, unknown>))
      .filter((v) => v.status === 'published')
      .sort((a, b) => b.version_number - a.version_number)[0]
    if (!published) continue
    results.push({ ...template, publishedVersion: published })
  }

  return results.sort((a, b) => {
    if (a.is_default !== b.is_default) return a.is_default ? -1 : 1
    return a.name.localeCompare(b.name)
  })
}

export async function listDefaultTemplates(
  tenantId: string,
): Promise<PublishedTemplateOption[]> {
  const templates = await listPublishedTemplatesForTenant(tenantId)
  return templates.filter((t) => t.is_default)
}

/**
 * Ordena i, opcionalment, filtra per idioma preferit del client.
 * Si no hi ha cap plantilla en aquell idioma, retorna totes (el caller pot avisar).
 */
export function sortTemplatesByPreferredLocale<T extends ChecklistTemplate>(
  templates: T[],
  preferredLocale?: string | null,
): T[] {
  if (!preferredLocale) return templates
  return [...templates].sort((a, b) => {
    const aMatch = a.locale === preferredLocale
    const bMatch = b.locale === preferredLocale
    if (aMatch !== bMatch) return aMatch ? -1 : 1
    if (a.is_default !== b.is_default) return a.is_default ? -1 : 1
    return a.name.localeCompare(b.name)
  })
}

export function filterTemplatesByPreferredLocale<T extends ChecklistTemplate>(
  templates: T[],
  preferredLocale?: string | null,
): { matched: T[]; hasPreferredMatch: boolean } {
  if (!preferredLocale) return { matched: templates, hasPreferredMatch: false }
  const matched = templates.filter((t) => t.locale === preferredLocale)
  return {
    matched: matched.length > 0 ? matched : templates,
    hasPreferredMatch: matched.length > 0,
  }
}

/** Idioma preferit del client (adreça d'obra primer, després el contacte). */
export async function getProjectPreferredLocale(projectId: string): Promise<string | null> {
  const { data: projectRow, error: projectError } = await supabase
    .from('projects')
    .select('client_id, contact_site_id')
    .eq('id', projectId)
    .maybeSingle()
  if (projectError) throw projectError
  if (!projectRow) return null

  const row = projectRow as unknown as {
    client_id: string | null
    contact_site_id: string | null
  }

  if (row.contact_site_id) {
    const { data, error } = await supabase
      .from('contact_sites')
      .select('preferred_locale')
      .eq('id', row.contact_site_id)
      .maybeSingle()
    if (error) throw error
    const locale = (data as unknown as { preferred_locale: string | null } | null)?.preferred_locale
    if (locale) return locale
  }

  if (row.client_id) {
    const { data, error } = await supabase
      .from('contacts')
      .select('preferred_locale')
      .eq('id', row.client_id)
      .maybeSingle()
    if (error) throw error
    const locale = (data as unknown as { preferred_locale: string | null } | null)?.preferred_locale
    if (locale) return locale
  }

  return null
}

export async function listRunsForProject(projectId: string): Promise<ChecklistRun[]> {
  const { data, error } = await supabase
    .from('checklist_runs')
    .select(`
      *,
      items:checklist_run_items(*)
    `)
    .eq('project_id', projectId)
    .order('sort_order', { ascending: true })
    .order('created_at', { ascending: true })

  if (error) throw error

  return ((data ?? []) as unknown as Record<string, unknown>[]).map((row) => {
    const run = mapRun(row)
    const items = ((row.items as unknown[]) ?? [])
      .map((i) => mapRunItem(i as Record<string, unknown>))
      .sort((a, b) => a.position - b.position)
    return { ...run, items }
  })
}

export async function applyChecklist(
  projectId: string,
  templateId: string,
  supersedeRunId?: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('apply_checklist_to_project', {
    p_project_id: projectId,
    p_template_id: templateId,
    p_supersede_run_id: supersedeRunId ?? undefined,
  })
  if (error) throw error
  return String(data)
}

/** Marca la run com a superseded (historial). No hi ha DELETE policy a checklist_runs. */
export async function removeChecklistRun(runId: string): Promise<void> {
  const { error } = await supabase
    .from('checklist_runs')
    .update({ status: 'superseded' })
    .eq('id', runId)
    .neq('status', 'superseded')
  if (error) throw error
}

/** Reordena les checklists actives de la visita (persistit als butlletins). */
export async function reorderChecklistRuns(
  projectId: string,
  runIds: string[],
): Promise<number> {
  const { data, error } = await supabase.rpc('reorder_checklist_runs', {
    p_project_id: projectId,
    p_run_ids: runIds,
  })
  if (error) throw error
  return Number(data ?? 0)
}

/**
 * Desa una resposta. Els camps `answer_*` (etiqueta, color, semàntica) els
 * congela la RPC a partir de l'opció triada.
 */
export async function answerRunItem(params: {
  itemId: string
  valueBool?: boolean | null
  valueOptionId?: string | null
  valueNumber?: number | null
  valueText?: string | null
  note?: string | null
  clientMutationId?: string
}): Promise<string> {
  const setValueBool = Object.prototype.hasOwnProperty.call(params, 'valueBool')
  const setValueOptionId = Object.prototype.hasOwnProperty.call(params, 'valueOptionId')
  const setValueNumber = Object.prototype.hasOwnProperty.call(params, 'valueNumber')
  const setValueText = Object.prototype.hasOwnProperty.call(params, 'valueText')
  const setNote = Object.prototype.hasOwnProperty.call(params, 'note')

  const { data, error } = await supabase.rpc('answer_checklist_run_item', {
    p_item_id: params.itemId,
    p_value_bool: setValueBool ? (params.valueBool ?? undefined) : undefined,
    p_value_option_id: setValueOptionId ? (params.valueOptionId ?? undefined) : undefined,
    p_value_number: setValueNumber ? (params.valueNumber ?? undefined) : undefined,
    p_value_text: setValueText ? (params.valueText ?? undefined) : undefined,
    p_note: setNote ? (params.note ?? undefined) : undefined,
    p_client_mutation_id: params.clientMutationId ?? undefined,
    p_set_value_bool: setValueBool,
    p_set_value_option_id: setValueOptionId,
    p_set_value_number: setValueNumber,
    p_set_value_text: setValueText,
    p_set_note: setNote,
  })
  if (error) throw error
  return String(data)
}

export async function setRunItemResolution(params: {
  itemId: string
  resolutionStatus: ResolutionStatus
  resolutionReason?: string | null
  resolutionNote?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('set_checklist_run_item_resolution', {
    p_item_id: params.itemId,
    p_resolution_status: params.resolutionStatus,
    p_resolution_reason: params.resolutionReason ?? undefined,
    p_resolution_note: params.resolutionNote ?? undefined,
  })
  if (error) throw error
  return String(data)
}

/** Idempotent: ensure a follow-up task exists for a deferred finding. */
export async function ensureDeferredTask(itemId: string): Promise<string> {
  const { data, error } = await supabase.rpc('ensure_checklist_deferred_task', {
    p_item_id: itemId,
  })
  if (error) throw error
  return String(data)
}

/** True if any active fail finding is deferred (for UI lists). */
export function projectHasDeferredFindings(runs: ChecklistRun[]): boolean {
  return runs
    .filter((r) => r.status !== 'superseded')
    .some((r) =>
      (r.items ?? []).some(
        (i) =>
          (i.answer_semantic === 'fail' || i.answer_blocks_closeout === true) &&
          i.resolution_status === 'deferred',
      ),
    )
}

/**
 * Deferred findings that still need work on this project.
 * False when a non-cancelled follow-up WO exists (handed off).
 */
export function projectNeedsOnHoldForDeferred(
  runs: ChecklistRun[],
  hasFollowUpWorkOrder: boolean,
): boolean {
  if (hasFollowUpWorkOrder) return false
  return projectHasDeferredFindings(runs)
}

export function isFindingItem(item: ChecklistRunItem): boolean {
  return item.answer_semantic === 'fail' || item.answer_blocks_closeout === true
}

export function listDeferredFindingItemIds(runs: ChecklistRun[]): string[] {
  const ids: string[] = []
  for (const run of runs) {
    if (run.status === 'superseded') continue
    for (const item of run.items ?? []) {
      if (isFindingItem(item) && item.resolution_status === 'deferred') {
        ids.push(item.id)
      }
    }
  }
  return ids
}

export async function getCloseoutBlockers(projectId: string): Promise<CloseoutBlocker[]> {
  const { data, error } = await supabase.rpc('checklist_closeout_blockers', {
    p_project_id: projectId,
  })
  if (error) throw error
  if (!Array.isArray(data)) return []
  return data as unknown as CloseoutBlocker[]
}

export async function buildPublicReport(
  projectId: string,
  locale?: string,
  bypassReason?: string,
): Promise<Json> {
  const { data, error } = await supabase.rpc('build_checklist_public_report', {
    p_project_id: projectId,
    p_locale: locale ?? undefined,
    p_bypass_reason: bypassReason ?? undefined,
  })
  if (error) throw error
  return data as Json
}

export async function buildAndPersistPublicReport(
  projectId: string,
  locale?: string,
  bypassReason?: string,
): Promise<Json> {
  const { data, error } = await supabase.rpc(
    'build_and_persist_checklist_public_report',
    {
      p_project_id: projectId,
      p_locale: locale ?? undefined,
      p_bypass_reason: bypassReason ?? undefined,
    },
  )
  if (error) {
    const missing =
      error.code === 'PGRST202'
      || error.message?.includes('build_and_persist_checklist_public_report')
    if (missing) {
      return buildPublicReport(projectId, locale, bypassReason)
    }
    throw error
  }
  return data as Json
}

export function isRunItemAnswered(item: ChecklistRunItem): boolean {
  if (item.response_type === 'checkbox') return item.value_bool === true
  return item.value_option_id != null
}

export function runProgress(run: ChecklistRun): { answered: number; total: number } {
  const items = run.items ?? []
  return { answered: items.filter(isRunItemAnswered).length, total: items.length }
}

/** Infer kind from run items (runs do not snapshot template.kind). */
export function runKind(run: ChecklistRun): ChecklistKind {
  return (run.items ?? []).some((i) => i.response_type === 'single_choice') ? 'review' : 'todo'
}

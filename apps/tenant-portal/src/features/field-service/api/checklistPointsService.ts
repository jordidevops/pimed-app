import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'

export type ChecklistLocale = 'ca' | 'es' | 'en'
export const CHECKLIST_LOCALES: ChecklistLocale[] = ['ca', 'es', 'en']

export interface ChecklistReviewPoint {
  id: string
  tenant_id: string | null
  title: string
  description: string | null
  client_text: string | null
  locale: ChecklistLocale
  category: string
  vertical: string
  archetype: string
  metadata: Record<string, unknown>
  catalog_version: number
  is_active: boolean
  is_archived: boolean
  created_by: string | null
  created_at: string | null
  updated_at: string | null
  /** Nombre de files de plantilla que referencien aquest punt (si s'ha carregat). */
  usage_count?: number
}

export interface ChecklistReviewPointFork {
  id: string
  source_point_id: string
  source_version_at_fork: number
  tenant_point_id: string
  tenant_id: string
  created_at: string | null
}

export interface PointForkStatus {
  tenantPointId: string
  sourcePointId: string
  forkVersion: number
  sourceVersion: number
  updateAvailable: boolean
}

export interface PointUsage {
  templateId: string
  templateName: string
  versionNumber: number
  versionStatus: string
}

export interface ReviewPointFilters {
  q?: string
  locale?: string
  category?: string
  limit?: number
  offset?: number
  includeArchived?: boolean
}

export interface PagedPoints {
  rows: ChecklistReviewPoint[]
  total: number
}

export const POINTS_PAGE_SIZE = 20

function mapPoint(row: Record<string, unknown>): ChecklistReviewPoint {
  return {
    id: String(row.id),
    tenant_id: row.tenant_id != null ? String(row.tenant_id) : null,
    title: String(row.title ?? ''),
    description: row.description != null ? String(row.description) : null,
    client_text: row.client_text != null ? String(row.client_text) : null,
    locale: (row.locale as ChecklistLocale) ?? 'ca',
    category: String(row.category ?? 'general'),
    vertical: String(row.vertical ?? 'generic'),
    archetype: String(row.archetype ?? 'generic'),
    metadata: (row.metadata as Record<string, unknown>) ?? {},
    catalog_version: Number(row.catalog_version ?? 1),
    is_active: row.is_active !== false,
    is_archived: row.is_archived === true,
    created_by: row.created_by != null ? String(row.created_by) : null,
    created_at: (row.created_at as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
  }
}

function mapFork(row: Record<string, unknown>): ChecklistReviewPointFork {
  return {
    id: String(row.id),
    source_point_id: String(row.source_point_id),
    source_version_at_fork: Number(row.source_version_at_fork ?? 1),
    tenant_point_id: String(row.tenant_point_id),
    tenant_id: String(row.tenant_id),
    created_at: (row.created_at as string | null) ?? null,
  }
}

// PostgREST separa els filtres d'`or()` per comes: cal netejar la cerca lliure.
function sanitizeSearch(q: string): string {
  return q.replace(/[,()*\\]/g, ' ').trim()
}

async function listPoints(
  scope: { tenantId: string } | { platform: true },
  filters: ReviewPointFilters,
): Promise<PagedPoints> {
  const limit = filters.limit ?? POINTS_PAGE_SIZE
  const offset = filters.offset ?? 0

  let query = supabase
    .from('checklist_review_points')
    .select('*', { count: 'exact' })

  query = 'tenantId' in scope
    ? query.eq('tenant_id', scope.tenantId)
    : query.is('tenant_id', null)

  if (!filters.includeArchived) query = query.eq('is_archived', false)
  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category)

  const search = sanitizeSearch(filters.q ?? '')
  if (search) {
    query = query.or(`title.ilike.%${search}%,description.ilike.%${search}%`)
  }

  const { data, error, count } = await query
    .order('title', { ascending: true })
    .range(offset, offset + limit - 1)

  if (error) throw error

  const rows = ((data ?? []) as unknown as Record<string, unknown>[]).map(mapPoint)
  const usage = await countPointUsage(rows.map((r) => r.id))
  return {
    rows: rows.map((row) => ({ ...row, usage_count: usage.get(row.id) ?? 0 })),
    total: count ?? 0,
  }
}

async function countPointUsage(pointIds: string[]): Promise<Map<string, number>> {
  const usage = new Map<string, number>()
  if (pointIds.length === 0) return usage

  const { data, error } = await supabase
    .from('checklist_template_items')
    .select('review_point_id')
    .in('review_point_id', pointIds)
  if (error) throw error

  for (const raw of (data ?? []) as unknown as Record<string, unknown>[]) {
    const id = raw.review_point_id != null ? String(raw.review_point_id) : null
    if (!id) continue
    usage.set(id, (usage.get(id) ?? 0) + 1)
  }
  return usage
}

export function listTenantPoints(
  tenantId: string,
  filters: ReviewPointFilters = {},
): Promise<PagedPoints> {
  return listPoints({ tenantId }, filters)
}

export function listPlatformPoints(filters: ReviewPointFilters = {}): Promise<PagedPoints> {
  return listPoints({ platform: true }, filters)
}

export async function getPoint(pointId: string): Promise<ChecklistReviewPoint> {
  const { data, error } = await supabase
    .from('checklist_review_points')
    .select('*')
    .eq('id', pointId)
    .single()
  if (error) throw error
  return mapPoint(data as unknown as Record<string, unknown>)
}

/** Categories presents al catàleg, per omplir el filtre. */
export async function listPointCategories(tenantId: string | null): Promise<string[]> {
  let query = supabase.from('checklist_review_points').select('category')
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

export async function createPoint(params: {
  tenant_id: string
  title: string
  description?: string | null
  client_text?: string | null
  locale?: ChecklistLocale
  category?: string | null
}): Promise<string> {
  const payload = {
    tenant_id: params.tenant_id,
    title: params.title.trim(),
    description: params.description?.trim() || null,
    client_text: params.client_text?.trim() || null,
    locale: params.locale ?? 'ca',
    category: params.category?.trim() || 'general',
  }

  const { data, error } = await supabase
    .from('checklist_review_points')
    .insert(payload)
    .select('id')
    .single()
  if (error) throw error
  return String((data as unknown as { id: string }).id)
}

export async function updatePoint(
  pointId: string,
  patch: {
    title?: string
    description?: string | null
    client_text?: string | null
    locale?: ChecklistLocale
    category?: string | null
    is_active?: boolean
    metadata?: Json
  },
): Promise<void> {
  const payload: Record<string, unknown> = {}
  if (patch.title !== undefined) payload.title = patch.title.trim()
  if (patch.description !== undefined) payload.description = patch.description?.trim() || null
  if (patch.client_text !== undefined) payload.client_text = patch.client_text?.trim() || null
  if (patch.locale !== undefined) payload.locale = patch.locale
  if (patch.category !== undefined) payload.category = patch.category?.trim() || 'general'
  if (patch.is_active !== undefined) payload.is_active = patch.is_active
  if (patch.metadata !== undefined) payload.metadata = patch.metadata
  if (Object.keys(payload).length === 0) return

  const { error } = await supabase
    .from('checklist_review_points')
    .update(payload)
    .eq('id', pointId)
  if (error) throw error
}

/** Arxiva el punt si alguna plantilla el referencia; si no, l'esborra. */
export async function archiveOrDeletePoint(pointId: string): Promise<'archived' | 'deleted'> {
  const { data, error } = await supabase.rpc('archive_or_delete_review_point', {
    p_point_id: pointId,
  })
  if (error) throw error
  return (data as unknown as 'archived' | 'deleted') ?? 'archived'
}

/**
 * Clona un punt (de plataforma o del propi tenant) cap al tenant.
 * Amb `locale` o `title` sempre crea una variant nova; sense, reutilitza el
 * fork existent si encara no s'ha editat.
 */
export async function clonePoint(params: {
  sourcePointId: string
  tenantId: string
  locale?: ChecklistLocale | null
  title?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('clone_checklist_review_point', {
    p_source_point_id: params.sourcePointId,
    p_tenant_id: params.tenantId,
    p_locale: params.locale ?? undefined,
    p_title: params.title?.trim() || undefined,
  })
  if (error) throw error
  return String(data)
}

export async function listPointForks(tenantId: string): Promise<ChecklistReviewPointFork[]> {
  const { data, error } = await supabase
    .from('checklist_review_point_forks')
    .select('*')
    .eq('tenant_id', tenantId)
  if (error) throw error
  return ((data ?? []) as unknown as Record<string, unknown>[]).map(mapFork)
}

/**
 * Estat de sincronització dels punts clonats: hi ha actualització disponible
 * quan el punt origen ha canviat després del fork.
 */
export async function listPointForkStatus(
  tenantId: string,
): Promise<Map<string, PointForkStatus>> {
  const forks = await listPointForks(tenantId)
  const result = new Map<string, PointForkStatus>()
  if (forks.length === 0) return result

  const sourceIds = [...new Set(forks.map((f) => f.source_point_id))]
  const { data, error } = await supabase
    .from('checklist_review_points')
    .select('id, catalog_version')
    .in('id', sourceIds)
  if (error) throw error

  const versionById = new Map<string, number>()
  for (const raw of (data ?? []) as unknown as Record<string, unknown>[]) {
    versionById.set(String(raw.id), Number(raw.catalog_version ?? 1))
  }

  for (const fork of forks) {
    const sourceVersion = versionById.get(fork.source_point_id)
    if (sourceVersion == null) continue
    result.set(fork.tenant_point_id, {
      tenantPointId: fork.tenant_point_id,
      sourcePointId: fork.source_point_id,
      forkVersion: fork.source_version_at_fork,
      sourceVersion,
      updateAvailable: fork.source_version_at_fork < sourceVersion,
    })
  }
  return result
}

/** Plantilles (versions) que referencien el punt. */
export async function listPointUsage(pointId: string): Promise<PointUsage[]> {
  const { data: itemRows, error: itemError } = await supabase
    .from('checklist_template_items')
    .select('version_id')
    .eq('review_point_id', pointId)
  if (itemError) throw itemError

  const versionIds = [
    ...new Set(
      ((itemRows ?? []) as unknown as Record<string, unknown>[]).map((r) => String(r.version_id)),
    ),
  ]
  if (versionIds.length === 0) return []

  const { data: versionRows, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, template_id, version_number, status')
    .in('id', versionIds)
  if (versionError) throw versionError

  const versions = ((versionRows ?? []) as unknown as Record<string, unknown>[]).map((r) => ({
    id: String(r.id),
    templateId: String(r.template_id),
    versionNumber: Number(r.version_number ?? 0),
    status: String(r.status ?? 'draft'),
  }))
  const templateIds = [...new Set(versions.map((v) => v.templateId))]
  if (templateIds.length === 0) return []

  const { data: templateRows, error: templateError } = await supabase
    .from('checklist_templates')
    .select('id, name')
    .in('id', templateIds)
  if (templateError) throw templateError

  const nameById = new Map<string, string>()
  for (const raw of (templateRows ?? []) as unknown as Record<string, unknown>[]) {
    nameById.set(String(raw.id), String(raw.name ?? ''))
  }

  return versions
    .map((v) => ({
      templateId: v.templateId,
      templateName: nameById.get(v.templateId) ?? v.templateId,
      versionNumber: v.versionNumber,
      versionStatus: v.status,
    }))
    .sort((a, b) => a.templateName.localeCompare(b.templateName) || a.versionNumber - b.versionNumber)
}

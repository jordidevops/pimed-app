'use server'

import { revalidatePath } from 'next/cache'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { assertBackofficeRole } from '@/lib/platform-catalog/server'
import {
  assertArchetype,
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
  type PagedResult,
} from '@/lib/platform-catalog/constants'

const POINTS_PATH = '/dashboard/settings/checklist-points'
const TEMPLATES_PATH = '/dashboard/settings/checklist-templates'

const POINT_COLUMNS =
  'id, title, description, client_text, locale, category, vertical, archetype, catalog_version, is_active, is_archived, created_at, updated_at'

export interface PlatformReviewPoint {
  id: string
  title: string
  description: string | null
  client_text: string | null
  locale: string
  category: string
  vertical: string
  archetype: string
  catalog_version: number
  is_active: boolean
  is_archived: boolean
  created_at: string | null
  updated_at: string | null
  /** How many platform/tenant template items reference this point. */
  usage_count?: number
}

export interface ReviewPointInput {
  title: string
  description?: string | null
  client_text?: string | null
  locale?: string
  category?: string
  vertical?: string
  archetype?: string
  is_active?: boolean
}

export interface ReviewPointFacets {
  categories: string[]
  verticals: string[]
}

function mapPoint(raw: unknown): PlatformReviewPoint {
  const row = asRecord(raw)
  return {
    id: str(row.id),
    title: str(row.title),
    description: nullableStr(row.description),
    client_text: nullableStr(row.client_text),
    locale: str(row.locale, 'ca'),
    category: str(row.category, 'general'),
    vertical: str(row.vertical, 'generic'),
    archetype: str(row.archetype, 'generic'),
    catalog_version: num(row.catalog_version, 1),
    is_active: row.is_active !== false,
    is_archived: row.is_archived === true,
    created_at: nullableStr(row.created_at),
    updated_at: nullableStr(row.updated_at),
  }
}

export async function listPlatformReviewPoints(
  filters: CatalogFilters = {},
): Promise<PagedResult<PlatformReviewPoint>> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()
  const { page, size, from, to } = resolvePaging(filters.page, filters.pageSize)

  let query = supabase
    .from('checklist_review_points')
    .select(POINT_COLUMNS, { count: 'exact' })
    .is('tenant_id', null)

  if (!filters.includeArchived) query = query.eq('is_archived', false)
  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category.toLowerCase())
  if (filters.vertical) query = query.eq('vertical', filters.vertical.toLowerCase())
  if (filters.archetype) query = query.eq('archetype', filters.archetype)

  const search = sanitizeSearch(filters.search)
  if (search) query = query.or(`title.ilike.%${search}%,description.ilike.%${search}%`)

  const { data, error, count } = await query
    .order('category', { ascending: true })
    .order('title', { ascending: true })
    .range(from, to)
  if (error) throw new Error(describeDbError(error))

  const rows = (data ?? []).map(mapPoint)
  const usage = await countPointUsage(rows.map((r) => r.id))
  const total = count ?? rows.length

  return {
    rows: rows.map((row) => ({ ...row, usage_count: usage.get(row.id) ?? 0 })),
    total,
    page,
    pageSize: size,
    pageCount: pageCount(total, size),
  }
}

async function countPointUsage(pointIds: string[]): Promise<Map<string, number>> {
  const usage = new Map<string, number>()
  if (pointIds.length === 0) return usage

  const supabase = createSupabaseAdminClient()
  const { data, error } = await supabase
    .from('checklist_template_items')
    .select('id, review_point_id')
    .in('review_point_id', pointIds)
  if (error) throw new Error(describeDbError(error))

  for (const raw of data ?? []) {
    const pointId = str(asRecord(raw).review_point_id)
    if (!pointId) continue
    usage.set(pointId, (usage.get(pointId) ?? 0) + 1)
  }
  return usage
}

/** Distinct category/vertical values, used to populate the filter dropdowns. */
export async function getPlatformReviewPointFacets(): Promise<ReviewPointFacets> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  const { data, error } = await supabase
    .from('checklist_review_points')
    .select('category, vertical')
    .is('tenant_id', null)
  if (error) throw new Error(describeDbError(error))

  const categories = new Set<string>()
  const verticals = new Set<string>()
  for (const raw of data ?? []) {
    const row = asRecord(raw)
    categories.add(str(row.category, 'general'))
    verticals.add(str(row.vertical, 'generic'))
  }

  return {
    categories: [...categories].sort(),
    verticals: [...verticals].sort(),
  }
}

/** Active platform points, for the checklist template item picker. */
export async function listPlatformReviewPointOptions(filters: {
  locale?: string
  category?: string
  vertical?: string
  search?: string
} = {}): Promise<PlatformReviewPoint[]> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  let query = supabase
    .from('checklist_review_points')
    .select(POINT_COLUMNS)
    .is('tenant_id', null)
    .eq('is_active', true)
    .eq('is_archived', false)

  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category.toLowerCase())
  if (filters.vertical) query = query.eq('vertical', filters.vertical.toLowerCase())

  const search = sanitizeSearch(filters.search)
  if (search) query = query.or(`title.ilike.%${search}%,description.ilike.%${search}%`)

  const { data, error } = await query
    .order('category', { ascending: true })
    .order('title', { ascending: true })
    .limit(300)
  if (error) throw new Error(describeDbError(error))

  return (data ?? []).map(mapPoint)
}

function buildPointPayload(input: ReviewPointInput): Record<string, unknown> {
  const title = input.title.trim()
  if (!title) throw new Error('El títol del punt és obligatori.')

  return {
    tenant_id: null,
    title,
    description: input.description?.trim() || null,
    client_text: input.client_text?.trim() || null,
    locale: assertLocale(input.locale),
    category: normalizeTaxonomy(input.category, 'general'),
    vertical: normalizeTaxonomy(input.vertical, 'generic'),
    archetype: assertArchetype(input.archetype),
    is_active: input.is_active ?? true,
  }
}

export async function createPlatformReviewPoint(input: ReviewPointInput): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase.from('checklist_review_points').insert(buildPointPayload(input))
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(POINTS_PATH)
  return { ok: true, message: 'Punt de revisió creat' }
}

export async function updatePlatformReviewPoint(
  pointId: string,
  input: ReviewPointInput,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const payload = buildPointPayload(input)
  delete payload.tenant_id

  const { error } = await supabase
    .from('checklist_review_points')
    .update(payload)
    .eq('id', pointId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(POINTS_PATH)
  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Punt de revisió actualitzat' }
}

export async function setPlatformReviewPointActive(
  pointId: string,
  isActive: boolean,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase
    .from('checklist_review_points')
    .update({ is_active: isActive })
    .eq('id', pointId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(POINTS_PATH)
  return { ok: true, message: isActive ? 'Punt activat' : 'Punt desactivat' }
}

/**
 * Archives the point when a template item references it (the FK is ON DELETE
 * RESTRICT) or a tenant has forked it, so clone lineage is never dropped
 * silently. Only genuinely unused points are removed.
 */
export async function deletePlatformReviewPoint(pointId: string): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { data: itemRefs, error: itemError } = await supabase
    .from('checklist_template_items')
    .select('id')
    .eq('review_point_id', pointId)
    .limit(1)
  if (itemError) return { ok: false, message: describeDbError(itemError) }

  const { data: forkRefs, error: forkError } = await supabase
    .from('checklist_review_point_forks')
    .select('id')
    .eq('source_point_id', pointId)
    .limit(1)
  if (forkError) return { ok: false, message: describeDbError(forkError) }

  const inUse = (itemRefs ?? []).length > 0 || (forkRefs ?? []).length > 0
  if (inUse) {
    const { error } = await supabase
      .from('checklist_review_points')
      .update({ is_archived: true, is_active: false })
      .eq('id', pointId)
      .is('tenant_id', null)
    if (error) return { ok: false, message: describeDbError(error) }

    revalidatePath(POINTS_PATH)
    return {
      ok: true,
      message: 'El punt està en ús (plantilles o clons de tenant): s\'ha arxivat en lloc d\'esborrar-lo',
    }
  }

  const { error } = await supabase
    .from('checklist_review_points')
    .delete()
    .eq('id', pointId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(POINTS_PATH)
  return { ok: true, message: 'Punt de revisió esborrat' }
}

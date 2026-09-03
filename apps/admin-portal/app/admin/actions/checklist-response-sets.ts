'use server'

import { revalidatePath } from 'next/cache'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { assertBackofficeRole } from '@/lib/platform-catalog/server'
import {
  assertAnswerSemantic,
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
  type ChecklistAnswerSemantic,
  type PagedResult,
} from '@/lib/platform-catalog/constants'

const SETS_PATH = '/dashboard/settings/checklist-response-sets'
const TEMPLATES_PATH = '/dashboard/settings/checklist-templates'

export interface PlatformResponseOption {
  id: string
  label: string
  semantics: ChecklistAnswerSemantic
  position: number
  blocks_closeout: boolean
  requires_note: boolean
  color_token: string | null
  /** True when option is referenced by published templates or run answers. */
  locked: boolean
}

export interface PlatformResponseSet {
  id: string
  name: string
  code: string | null
  locale: string
  category: string
  vertical: string
  is_active: boolean
  created_at: string | null
  updated_at: string | null
  options: PlatformResponseOption[]
  /** Set is used by at least one published template version. */
  published_locked: boolean
}

export interface ResponseOptionInput {
  id?: string | null
  label: string
  semantics: string
  position?: number
  blocks_closeout?: boolean
  requires_note?: boolean
  color_token?: string | null
}

export interface ResponseSetInput {
  name: string
  code?: string | null
  locale?: string
  category?: string
  vertical?: string
  is_active?: boolean
  options: ResponseOptionInput[]
}

function mapOption(
  raw: unknown,
  lockedIds: Set<string>,
): PlatformResponseOption {
  const row = asRecord(raw)
  const id = str(row.id)
  return {
    id,
    label: str(row.label),
    semantics: str(row.semantics, 'neutral') as ChecklistAnswerSemantic,
    position: num(row.position, 0),
    blocks_closeout: row.blocks_closeout === true,
    requires_note: row.requires_note === true,
    color_token: nullableStr(row.color_token),
    locked: lockedIds.has(id),
  }
}

function mapSet(
  raw: unknown,
  options: PlatformResponseOption[],
  publishedLocked: boolean,
): PlatformResponseSet {
  const row = asRecord(raw)
  return {
    id: str(row.id),
    name: str(row.name),
    code: nullableStr(row.code),
    locale: str(row.locale, 'ca'),
    category: str(row.category, 'general'),
    vertical: str(row.vertical, 'generic'),
    is_active: row.is_active !== false,
    created_at: nullableStr(row.created_at),
    updated_at: nullableStr(row.updated_at),
    options,
    published_locked: publishedLocked,
  }
}

async function publishedSetIds(setIds: string[]): Promise<Set<string>> {
  const locked = new Set<string>()
  if (setIds.length === 0) return locked
  const supabase = createSupabaseAdminClient()

  const { data: versions, error: versionError } = await supabase
    .from('checklist_template_versions')
    .select('id, default_response_set_id')
    .eq('status', 'published')
    .in('default_response_set_id', setIds)
  if (versionError) throw new Error(describeDbError(versionError))
  for (const raw of versions ?? []) {
    const id = nullableStr(asRecord(raw).default_response_set_id)
    if (id) locked.add(id)
  }

  const versionIds = (versions ?? []).map((raw) => str(asRecord(raw).id)).filter(Boolean)
  // Also sets used as per-item override on any published version.
  const { data: allPublished, error: pubError } = await supabase
    .from('checklist_template_versions')
    .select('id')
    .eq('status', 'published')
  if (pubError) throw new Error(describeDbError(pubError))
  const allPubIds = (allPublished ?? []).map((raw) => str(asRecord(raw).id))
  if (allPubIds.length > 0) {
    const { data: items, error: itemError } = await supabase
      .from('checklist_template_items')
      .select('response_set_id')
      .in('version_id', allPubIds)
      .in('response_set_id', setIds)
    if (itemError) throw new Error(describeDbError(itemError))
    for (const raw of items ?? []) {
      const id = nullableStr(asRecord(raw).response_set_id)
      if (id) locked.add(id)
    }
  }

  void versionIds
  return locked
}

async function lockedOptionIds(optionIds: string[]): Promise<Set<string>> {
  const locked = new Set<string>()
  if (optionIds.length === 0) return locked
  const supabase = createSupabaseAdminClient()

  const { data: runRefs, error: runError } = await supabase
    .from('checklist_run_items')
    .select('value_option_id')
    .in('value_option_id', optionIds)
  if (runError) throw new Error(describeDbError(runError))
  for (const raw of runRefs ?? []) {
    const id = nullableStr(asRecord(raw).value_option_id)
    if (id) locked.add(id)
  }
  return locked
}

export async function listPlatformResponseSetsAdmin(
  filters: CatalogFilters = {},
): Promise<PagedResult<PlatformResponseSet>> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()
  const { page, size, from, to } = resolvePaging(filters.page, filters.pageSize)

  let query = supabase
    .from('checklist_response_sets')
    .select('id, name, code, locale, category, vertical, is_active, created_at, updated_at', {
      count: 'exact',
    })
    .is('tenant_id', null)

  if (!filters.includeArchived) query = query.eq('is_active', true)
  if (filters.locale) query = query.eq('locale', filters.locale)
  if (filters.category) query = query.eq('category', filters.category.toLowerCase())
  if (filters.vertical) query = query.eq('vertical', filters.vertical.toLowerCase())

  const search = sanitizeSearch(filters.search)
  if (search) query = query.or(`name.ilike.%${search}%,code.ilike.%${search}%`)

  const { data, error, count } = await query
    .order('name', { ascending: true })
    .range(from, to)
  if (error) throw new Error(describeDbError(error))

  const bases = (data ?? []).map(asRecord)
  const setIds = bases.map((row) => str(row.id))
  if (setIds.length === 0) {
    return { rows: [], total: 0, page, pageSize: size, pageCount: 1 }
  }

  const { data: optionRows, error: optionError } = await supabase
    .from('checklist_response_options')
    .select(
      'id, response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token',
    )
    .in('response_set_id', setIds)
    .order('position', { ascending: true })
  if (optionError) throw new Error(describeDbError(optionError))

  const allOptionIds = (optionRows ?? []).map((raw) => str(asRecord(raw).id))
  const [optLocked, setLocked] = await Promise.all([
    lockedOptionIds(allOptionIds),
    publishedSetIds(setIds),
  ])

  const optionsBySet = new Map<string, PlatformResponseOption[]>()
  for (const raw of optionRows ?? []) {
    const row = asRecord(raw)
    const setId = str(row.response_set_id)
    const list = optionsBySet.get(setId) ?? []
    list.push(mapOption(row, optLocked))
    optionsBySet.set(setId, list)
  }

  const rows = bases.map((row) => {
    const id = str(row.id)
    return mapSet(row, optionsBySet.get(id) ?? [], setLocked.has(id))
  })

  const total = count ?? rows.length
  return {
    rows,
    total,
    page,
    pageSize: size,
    pageCount: pageCount(total, size),
  }
}

export async function getPlatformResponseSet(
  setId: string,
): Promise<PlatformResponseSet | null> {
  await assertBackofficeRole()
  const supabase = createSupabaseAdminClient()

  const { data, error } = await supabase
    .from('checklist_response_sets')
    .select('id, name, code, locale, category, vertical, is_active, created_at, updated_at')
    .eq('id', setId)
    .is('tenant_id', null)
    .maybeSingle()
  if (error) throw new Error(describeDbError(error))
  if (!data) return null

  const { data: optionRows, error: optionError } = await supabase
    .from('checklist_response_options')
    .select(
      'id, response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token',
    )
    .eq('response_set_id', setId)
    .order('position', { ascending: true })
  if (optionError) throw new Error(describeDbError(optionError))

  const optionIds = (optionRows ?? []).map((raw) => str(asRecord(raw).id))
  const [optLocked, setLocked] = await Promise.all([
    lockedOptionIds(optionIds),
    publishedSetIds([setId]),
  ])

  return mapSet(
    data,
    (optionRows ?? []).map((raw) => mapOption(raw, optLocked)),
    setLocked.has(setId),
  )
}

function normalizeOptions(options: ResponseOptionInput[]): ResponseOptionInput[] {
  if (!options.length) throw new Error('Cal almenys una opció de resposta.')
  return options.map((opt, index) => {
    const label = opt.label.trim()
    if (!label) throw new Error(`L'opció ${index + 1} no té etiqueta.`)
    return {
      id: opt.id ?? null,
      label,
      semantics: assertAnswerSemantic(opt.semantics),
      position: opt.position ?? index,
      blocks_closeout: opt.blocks_closeout === true,
      requires_note: opt.requires_note === true,
      color_token: opt.color_token?.trim() || null,
    }
  })
}

export async function createPlatformResponseSet(
  input: ResponseSetInput,
): Promise<ActionResult & { setId?: string }> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()
  const options = normalizeOptions(input.options)
  const name = input.name.trim()
  if (!name) return { ok: false, message: 'El nom és obligatori.' }

  const { data, error } = await supabase
    .from('checklist_response_sets')
    .insert({
      tenant_id: null,
      name,
      code: input.code?.trim() || null,
      locale: assertLocale(input.locale),
      category: normalizeTaxonomy(input.category, 'general'),
      vertical: normalizeTaxonomy(input.vertical, 'generic'),
      is_active: input.is_active ?? true,
    })
    .select('id')
    .single()
  if (error) return { ok: false, message: describeDbError(error) }

  const setId = str(asRecord(data).id)
  const { error: optError } = await supabase.from('checklist_response_options').insert(
    options.map((opt, index) => ({
      response_set_id: setId,
      label: opt.label,
      semantics: opt.semantics,
      position: index,
      blocks_closeout: opt.blocks_closeout === true,
      requires_note: opt.requires_note === true,
      color_token: opt.color_token,
    })),
  )
  if (optError) {
    await supabase.from('checklist_response_sets').delete().eq('id', setId)
    return { ok: false, message: describeDbError(optError) }
  }

  revalidatePath(SETS_PATH)
  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Conjunt creat', setId }
}

export async function updatePlatformResponseSet(
  setId: string,
  input: ResponseSetInput,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()
  const existing = await getPlatformResponseSet(setId)
  if (!existing) return { ok: false, message: 'Conjunt no trobat.' }

  const options = normalizeOptions(input.options)
  const name = input.name.trim()
  if (!name) return { ok: false, message: 'El nom és obligatori.' }

  const { error: setError } = await supabase
    .from('checklist_response_sets')
    .update({
      name,
      code: input.code?.trim() || null,
      locale: assertLocale(input.locale),
      category: normalizeTaxonomy(input.category, 'general'),
      vertical: normalizeTaxonomy(input.vertical, 'generic'),
      is_active: input.is_active ?? existing.is_active,
    })
    .eq('id', setId)
    .is('tenant_id', null)
  if (setError) return { ok: false, message: describeDbError(setError) }

  const lockedById = new Map(existing.options.map((o) => [o.id, o]))
  const keptIds = new Set<string>()

  for (const [index, opt] of options.entries()) {
    if (opt.id && lockedById.get(opt.id)?.locked) {
      const locked = lockedById.get(opt.id)!
      // Immutable core fields: only allow label polish if you want — plan says immutable.
      // Keep semantics/blocks/requires_note/color from locked row; allow position reorder via update of position only.
      const { error } = await supabase
        .from('checklist_response_options')
        .update({
          label: locked.label,
          semantics: locked.semantics,
          blocks_closeout: locked.blocks_closeout,
          requires_note: locked.requires_note,
          color_token: locked.color_token,
          position: index,
        })
        .eq('id', opt.id)
        .eq('response_set_id', setId)
      if (error) return { ok: false, message: describeDbError(error) }
      keptIds.add(opt.id)
      continue
    }

    if (opt.id) {
      const { error } = await supabase
        .from('checklist_response_options')
        .update({
          label: opt.label,
          semantics: opt.semantics,
          blocks_closeout: opt.blocks_closeout === true,
          requires_note: opt.requires_note === true,
          color_token: opt.color_token,
          position: index,
        })
        .eq('id', opt.id)
        .eq('response_set_id', setId)
      if (error) return { ok: false, message: describeDbError(error) }
      keptIds.add(opt.id)
    } else {
      const { data: inserted, error } = await supabase
        .from('checklist_response_options')
        .insert({
          response_set_id: setId,
          label: opt.label,
          semantics: opt.semantics,
          position: index,
          blocks_closeout: opt.blocks_closeout === true,
          requires_note: opt.requires_note === true,
          color_token: opt.color_token,
        })
        .select('id')
        .single()
      if (error) return { ok: false, message: describeDbError(error) }
      keptIds.add(str(asRecord(inserted).id))
    }
  }

  for (const old of existing.options) {
    if (keptIds.has(old.id)) continue
    if (old.locked || existing.published_locked) {
      return {
        ok: false,
        message:
          'No es pot eliminar una opció ja usada en respostes o plantilles publicades. Desactiva el conjunt i crea’n un de nou.',
      }
    }
    const { error } = await supabase
      .from('checklist_response_options')
      .delete()
      .eq('id', old.id)
      .eq('response_set_id', setId)
    if (error) return { ok: false, message: describeDbError(error) }
  }

  revalidatePath(SETS_PATH)
  revalidatePath(TEMPLATES_PATH)
  return { ok: true, message: 'Conjunt actualitzat' }
}

export async function setPlatformResponseSetActive(
  setId: string,
  isActive: boolean,
): Promise<ActionResult> {
  await assertBackofficeRole(['admin'])
  const supabase = createSupabaseAdminClient()

  const { error } = await supabase
    .from('checklist_response_sets')
    .update({ is_active: isActive })
    .eq('id', setId)
    .is('tenant_id', null)
  if (error) return { ok: false, message: describeDbError(error) }

  revalidatePath(SETS_PATH)
  revalidatePath(TEMPLATES_PATH)
  return {
    ok: true,
    message: isActive ? 'Conjunt activat' : 'Conjunt desactivat',
  }
}

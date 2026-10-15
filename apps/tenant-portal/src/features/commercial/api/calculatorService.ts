import { supabase } from '@/lib/supabase'
import {
  activationGaps,
  applyLineOverrides,
  hashLines,
  previewTotals,
  run,
  validateDefinition,
  type Definition,
  type LineOverrides,
  type LocaleMap,
  type OutputLine,
  type ParamValues,
} from '@pimed/price-calculator'
import { formatCalcErrorList } from '../utils/calculatorErrorLabels'

export type CalculatorDefinitionRow = {
  id: string
  name: string
  description: string | null
  status: 'draft' | 'incomplete' | 'active' | 'archived'
  draft_definition: Definition
  published_version_id: string | null
  tags: string[]
  updated_at?: string
  cloned_from_catalog_id?: string | null
  tariffs_reviewed_at?: string | null
}

export type CalculatorCaseRow = {
  id: string
  definition_id: string
  name: string
  params: ParamValues
  expected_lines: OutputLine[]
  last_result: 'unrun' | 'pass' | 'fail'
}

export async function listCalculators(opts?: {
  status?: CalculatorDefinitionRow['status'] | 'all'
  tag?: string | null
}): Promise<CalculatorDefinitionRow[]> {
  let q = supabase
    .from('calculator_definitions' as never)
    .select(
      'id, name, description, status, draft_definition, published_version_id, tags, updated_at, cloned_from_catalog_id',
    )
    .order('name')
  if (opts?.status && opts.status !== 'all') {
    q = q.eq('status', opts.status)
  }
  const { data, error } = await q
  if (error) throw error
  let rows = (data ?? []) as CalculatorDefinitionRow[]
  const tag = opts?.tag?.trim().toLowerCase()
  if (tag) {
    rows = rows.filter((r) => (r.tags ?? []).includes(tag))
  }
  return rows
}

export async function listActiveCalculators(): Promise<CalculatorDefinitionRow[]> {
  return listCalculators({ status: 'active' })
}

export async function getCalculatorDefinition(
  id: string,
): Promise<CalculatorDefinitionRow> {
  const { data, error } = await supabase
    .from('calculator_definitions' as never)
    .select(
      'id, name, description, status, draft_definition, published_version_id, tags, updated_at, cloned_from_catalog_id, tariffs_reviewed_at',
    )
    .eq('id', id)
    .single()
  if (error) throw error
  return data as CalculatorDefinitionRow
}

export async function markCalculatorTariffsReviewed(definitionId: string): Promise<void> {
  const { error } = await supabase.rpc('mark_calculator_tariffs_reviewed' as never, {
    p_definition_id: definitionId,
  } as never)
  if (error) throw error
}

export async function listCalculatorCases(
  definitionId: string,
): Promise<CalculatorCaseRow[]> {
  const { data, error } = await supabase
    .from('calculator_cases' as never)
    .select('id, definition_id, name, params, expected_lines, last_result')
    .eq('definition_id', definitionId)
    .order('created_at')
  if (error) throw error
  return (data ?? []) as CalculatorCaseRow[]
}

export async function listTenantCalculatorTags(): Promise<string[]> {
  const rows = await listCalculators({ status: 'all' })
  const set = new Set<string>()
  for (const row of rows) {
    for (const tag of row.tags ?? []) set.add(tag)
  }
  return [...set].sort((a, b) => a.localeCompare(b, 'ca'))
}

export type CalculatorCatalogDefaultCase = {
  name: string
  params: ParamValues
  expected_lines?: OutputLine[]
}

export type CalculatorCatalogRow = {
  id: string
  slug: string
  target_archetypes: string[]
  catalog_version: number
  definition: Definition
  tags: string[]
  is_active: boolean
  title?: LocaleMap | null
  summary?: LocaleMap | null
  default_case?: CalculatorCatalogDefaultCase | null
  /** True when shown only because cross-archetype catalog is enabled. */
  crossArchetype?: boolean
}

export type CalculatorCatalogSettings = {
  show_cross_archetype_catalog: boolean
}

export async function getCalculatorCatalogSettings(): Promise<CalculatorCatalogSettings> {
  try {
    const { data, error } = await supabase.rpc('get_calculator_catalog_settings' as never)
    if (error) throw error
    const raw = (data ?? {}) as Record<string, unknown>
    return {
      show_cross_archetype_catalog: raw.show_cross_archetype_catalog === true,
    }
  } catch {
    // Default safe: no cross-archetype until settings are readable.
    return { show_cross_archetype_catalog: false }
  }
}

function normalizeArchetypes(raw: unknown): string[] {
  if (Array.isArray(raw)) return raw.map((a) => String(a).trim()).filter(Boolean)
  if (typeof raw === 'string') {
    const trimmed = raw.trim()
    if (!trimmed) return []
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return trimmed
        .slice(1, -1)
        .split(',')
        .map((s) => s.trim().replace(/^"|"$/g, ''))
        .filter(Boolean)
    }
    return [trimmed]
  }
  return []
}

export async function listCalculatorCatalog(
  archetype: string | null | undefined,
  opts?: { allowCrossArchetype?: boolean },
): Promise<CalculatorCatalogRow[]> {
  // Prefer * so missing generated types (title/summary/default_case) cannot break the select.
  const primarySelect =
    'id, slug, target_archetypes, catalog_version, definition, tags, is_active, title, summary, default_case'
  const fallbackSelect =
    'id, slug, target_archetypes, catalog_version, definition, tags, is_active'

  let { data, error } = await supabase
    .from('calculator_catalog' as never)
    .select(primarySelect)
    .order('slug')

  if (error) {
    const msg = error.message ?? ''
    if (/title|summary|default_case|column/i.test(msg)) {
      ;({ data, error } = await supabase
        .from('calculator_catalog' as never)
        .select(fallbackSelect)
        .order('slug'))
    }
  }
  if (error) throw error

  const rows = ((data ?? []) as CalculatorCatalogRow[])
    .filter((r) => r.is_active !== false)
    .map((r) => ({
      ...r,
      target_archetypes: normalizeArchetypes(r.target_archetypes),
    }))
  const arch = (archetype ?? 'generic').trim() || 'generic'
  let matching = rows.filter((r) => r.target_archetypes.includes(arch))
  // field_service is the FSM vertical; also cover tenants still on generic profile
  if (matching.length === 0 && (arch === 'generic' || arch === 'field_service')) {
    matching = rows.filter(
      (r) =>
        r.target_archetypes.includes('field_service') ||
        r.target_archetypes.includes('generic'),
    )
  }
  const matchingIds = new Set(matching.map((r) => r.id))
  const primary = matching.map((r) => ({ ...r, crossArchetype: false as const }))
  if (!opts?.allowCrossArchetype) return primary
  const extra = rows
    .filter((r) => !matchingIds.has(r.id))
    .map((r) => ({ ...r, crossArchetype: true as const }))
  return [...primary, ...extra]
}

export async function cloneCalculatorFromCatalog(input: {
  catalogId: string
  name?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('clone_calculator_from_catalog' as never, {
    p_catalog_id: input.catalogId,
    p_name: input.name ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function createCalculatorDefinition(input: {
  name: string
  description?: string | null
  draftDefinition?: Definition
  tags?: string[]
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_calculator_definition' as never, {
    p_name: input.name,
    p_description: input.description ?? null,
    p_draft_definition: input.draftDefinition ?? null,
    p_tags: input.tags ?? [],
  } as never)
  if (error) throw error
  return data as string
}

export async function saveCalculatorDraft(input: {
  definitionId: string
  name?: string
  description?: string | null
  draftDefinition?: Definition
  tags?: string[]
}): Promise<void> {
  const { error } = await supabase.rpc('save_calculator_draft' as never, {
    p_definition_id: input.definitionId,
    p_name: input.name ?? null,
    p_description: input.description ?? null,
    p_draft_definition: input.draftDefinition ?? null,
    p_tags: input.tags ?? null,
  } as never)
  if (error) throw error
}

export async function getCalculatorVersion(versionId: string): Promise<{
  id: string
  definition_id: string
  definition: Definition
}> {
  const { data, error } = await supabase
    .from('calculator_versions' as never)
    .select('id, definition_id, definition')
    .eq('id', versionId)
    .single()
  if (error) throw error
  return data as { id: string; definition_id: string; definition: Definition }
}

/** Previsualització local (mateix motor que l'Edge). */
export function previewCalculator(
  definition: Definition,
  params: ParamValues,
  locale = 'ca',
  lineOverrides?: LineOverrides,
) {
  const result = run(definition, params, locale)
  if (result.errors.length) {
    return {
      ...result,
      totals: null,
      validation: validateDefinition(definition),
      gaps: activationGaps(definition),
    }
  }
  // Previsualització: fusiona sense bloquejar; validate=true només a apply.
  const merged = applyLineOverrides(result.lines, lineOverrides, definition, {
    validate: false,
  })
  const checked = applyLineOverrides(merged.lines, lineOverrides, definition, {
    validate: true,
  })
  return {
    lines: merged.lines,
    errors: checked.errors,
    totals:
      checked.errors.length === 0 ? previewTotals(merged.lines) : null,
    validation: validateDefinition(definition),
    gaps: activationGaps(definition),
  }
}

export function compareCaseLines(
  expected: OutputLine[],
  actual: OutputLine[],
): { ok: boolean; diffs: string[] } {
  const diffs: string[] = []
  const expKeys = new Set(expected.map((l) => l.key))
  const actKeys = new Set(actual.map((l) => l.key))
  for (const key of expKeys) {
    if (!actKeys.has(key)) diffs.push(`missing:${key}`)
  }
  for (const key of actKeys) {
    if (!expKeys.has(key)) diffs.push(`extra:${key}`)
  }
  for (const exp of expected) {
    const act = actual.find((l) => l.key === exp.key)
    if (!act) continue
    if (exp.quantity !== act.quantity) diffs.push(`${exp.key}.quantity`)
    if (exp.unit_price !== act.unit_price) diffs.push(`${exp.key}.unit_price`)
    if (exp.name !== act.name) diffs.push(`${exp.key}.name`)
  }
  return { ok: diffs.length === 0, diffs }
}

export async function upsertCalculatorCase(input: {
  definitionId: string
  name: string
  params: ParamValues
  expectedLines: OutputLine[]
  lastResult?: 'unrun' | 'pass' | 'fail'
  caseId?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_calculator_case' as never, {
    p_definition_id: input.definitionId,
    p_name: input.name,
    p_params: input.params,
    p_expected_lines: input.expectedLines,
    p_last_result: input.lastResult ?? 'unrun',
    p_case_id: input.caseId ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function deleteCalculatorCase(caseId: string): Promise<void> {
  const { error } = await supabase
    .from('calculator_cases' as never)
    .delete()
    .eq('id', caseId)
  if (error) throw error
}

export async function checkCalculatorCase(input: {
  definition: Definition
  caseRow: CalculatorCaseRow
}): Promise<{ result: 'pass' | 'fail'; diffs: string[]; lines: OutputLine[] }> {
  const preview = run(input.definition, input.caseRow.params, 'ca')
  if (preview.errors.length) {
    return {
      result: 'fail',
      diffs: preview.errors.map((e) =>
        formatCalcErrorList(input.definition, [e], 'ca'),
      ),
      lines: [],
    }
  }
  const cmp = compareCaseLines(input.caseRow.expected_lines, preview.lines)
  return {
    result: cmp.ok ? 'pass' : 'fail',
    diffs: cmp.diffs,
    lines: preview.lines,
  }
}

export async function applyCalculatorRun(input: {
  versionId: string
  params: ParamValues
  projectId?: string | null
  documentId?: string | null
  clientOpId: string
  /** Definició ja carregada (evita un trip extra si el caller la té). */
  definition: Definition
  lineOverrides?: LineOverrides
}): Promise<{ lines: OutputLine[]; lines_hash: string; result: unknown }> {
  const preview = run(input.definition, input.params, 'ca')
  if (preview.errors.length) {
    throw new Error(formatCalcErrorList(input.definition, preview.errors, 'ca'))
  }
  const overridden = applyLineOverrides(
    preview.lines,
    input.lineOverrides,
    input.definition,
  )
  if (overridden.errors.length) {
    throw new Error(formatCalcErrorList(input.definition, overridden.errors, 'ca'))
  }
  const linesHash = await hashLines(overridden.lines)

  const { data, error } = await supabase.functions.invoke('apply-calculator-run', {
    body: {
      version_id: input.versionId,
      params: input.params,
      lines_hash: linesHash,
      client_op_id: input.clientOpId,
      project_id: input.projectId ?? null,
      document_id: input.documentId ?? null,
      line_overrides: input.lineOverrides ?? {},
    },
  })

  if (error) throw error
  if (data?.error === 'calculator_parity_mismatch') {
    throw new Error('calculator_parity_mismatch')
  }
  if (data?.error) {
    throw new Error(String(data.message ?? data.error))
  }

  return {
    lines: (data?.lines ?? preview.lines) as OutputLine[],
    lines_hash: String(data?.lines_hash ?? linesHash),
    result: data?.result,
  }
}

export async function publishCalculatorVersion(definitionId: string): Promise<string> {
  const { data, error } = await supabase.rpc('publish_calculator_version' as never, {
    p_definition_id: definitionId,
    p_content_hash: null,
  } as never)
  if (error) throw error
  return data as string
}

export async function setCalculatorStatus(
  definitionId: string,
  status: CalculatorDefinitionRow['status'],
): Promise<void> {
  const { error } = await supabase.rpc('set_calculator_status' as never, {
    p_definition_id: definitionId,
    p_status: status,
  } as never)
  if (error) throw error
}

/** Esborra esborranys / incompletes / arxivades sense runs. Actives: arxivar abans. */
export async function deleteCalculatorDefinition(definitionId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_calculator_definition' as never, {
    p_definition_id: definitionId,
  } as never)
  if (error) throw error
}

export function canActivateCalculator(input: {
  definition: Definition
  hasPassingCase: boolean
  publishedVersionId: string | null
}): { ok: boolean; reasons: string[] } {
  const reasons: string[] = []
  const gaps = activationGaps(input.definition)
  if (gaps.length) reasons.push('incomplete_tariff')
  if (!input.publishedVersionId) reasons.push('not_published')
  if (!input.hasPassingCase) reasons.push('case_required')
  const validation = validateDefinition(input.definition)
  if (!validation.ok) reasons.push('invalid_definition')
  return { ok: reasons.length === 0, reasons }
}

export const EMPTY_CALCULATOR_DEFINITION: Definition = {
  schema_version: 1,
  parameters: [],
  constants: [],
  tables: [],
  lines: [],
}

/** Activa un clon ready: cas + publish + active. Falla si expected divergeix del motor. */
export async function activateClonedCalculator(input: {
  definitionId: string
  definition: Definition
  defaultCase: CalculatorCatalogDefaultCase
}): Promise<void> {
  const preview = previewCalculator(input.definition, input.defaultCase.params, 'ca')
  if (preview.errors.length) {
    throw new Error(formatCalcErrorList(input.definition, preview.errors, 'ca'))
  }
  if (preview.gaps.length) {
    throw new Error(
      `incomplete_tariff:${preview.gaps.map((g) => g.path).join(',')}`,
    )
  }
  const expected = input.defaultCase.expected_lines
  if (expected?.length) {
    const cmp = compareCaseLines(expected, preview.lines)
    if (!cmp.ok) {
      throw new Error(`default_case_mismatch:${cmp.diffs.join(',')}`)
    }
  }
  await upsertCalculatorCase({
    definitionId: input.definitionId,
    name: input.defaultCase.name,
    params: input.defaultCase.params,
    expectedLines: expected?.length ? expected : preview.lines,
    lastResult: 'pass',
  })
  await publishCalculatorVersion(input.definitionId)
  await setCalculatorStatus(input.definitionId, 'active')
}

/** Arxiva exemples seed (tag exemple). */
export async function archiveExampleCalculators(mode: 'duplicates' | 'all'): Promise<number> {
  const rows = await listCalculators({ status: 'all' })
  const examples = rows.filter(
    (r) => (r.tags ?? []).includes('exemple') && r.status !== 'archived',
  )
  let toArchive: CalculatorDefinitionRow[] = []
  if (mode === 'all') {
    toArchive = examples
  } else {
    const byName = new Map<string, CalculatorDefinitionRow[]>()
    for (const row of examples) {
      const list = byName.get(row.name) ?? []
      list.push(row)
      byName.set(row.name, list)
    }
    for (const list of byName.values()) {
      if (list.length < 2) continue
      const sorted = [...list].sort((a, b) =>
        String(b.updated_at ?? '').localeCompare(String(a.updated_at ?? '')),
      )
      toArchive.push(...sorted.slice(1))
    }
  }
  let archived = 0
  for (const row of toArchive) {
    await setCalculatorStatus(row.id, 'archived')
    archived += 1
  }
  return archived
}

/** @deprecated use archiveExampleCalculators('duplicates') */
export async function archiveDuplicateExampleCalculators(): Promise<number> {
  return archiveExampleCalculators('duplicates')
}

export { pickBestClone } from '../utils/pickBestClone'

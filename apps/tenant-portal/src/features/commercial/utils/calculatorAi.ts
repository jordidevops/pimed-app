import {
  KEY_RE,
  validateDefinition,
  type Constant,
  type Definition,
  type LineDef,
  type LookupTable,
  type Parameter,
} from '@pimed/price-calculator'

export type CalculatorFragmentKind = 'parameter' | 'constant' | 'table' | 'line'

export type CalculatorPatch = {
  op: 'add' | 'replace' | 'remove'
  path: string
  value?: unknown
}

/** Extreu nombres del text de l’usuari (per D15: xifres no dites → assumed). */
export function extractMentionedNumbers(text: string): Set<string> {
  const set = new Set<string>()
  const re = /\d+(?:[.,]\d+)?/g
  let m: RegExpExecArray | null
  while ((m = re.exec(text)) != null) {
    set.add(m[0].replace(',', '.'))
  }
  return set
}

function isMentioned(value: number, mentioned: Set<string>): boolean {
  const asFixed = String(value)
  const as2 = value.toFixed(2).replace(/\.?0+$/, '')
  return mentioned.has(asFixed) || mentioned.has(as2) || mentioned.has(String(Math.round(value)))
}

/**
 * D15: nombres de tarifa no presents al prompt → null + assumed.
 * No toca hours / max_km estructurals (claus sense eur/price/pct).
 */
export function demoteUnconfirmedTariffNumbers(
  definition: Definition,
  userPrompt: string,
): Definition {
  const mentioned = extractMentionedNumbers(userPrompt)
  const next = structuredClone(definition)
  for (const c of next.constants ?? []) {
    if (typeof c.value === 'number' && !isMentioned(c.value, mentioned)) {
      c.value = null
      c.assumed = true
    }
  }
  for (const table of next.tables ?? []) {
    for (const row of table.rows) {
      for (const [key, val] of Object.entries(row)) {
        if (key === 'id' || key === 'label' || key === 'assumed') continue
        if (!/eur|price|pct|amount|tariff|rate/i.test(key)) continue
        if (typeof val === 'number' && !isMentioned(val, mentioned)) {
          row[key] = null
          row.assumed = true
        }
      }
    }
  }
  return next
}

export function parseAiCalculatorDefinition(raw: string): Definition {
  const parsed = JSON.parse(raw) as unknown
  const candidate =
    parsed && typeof parsed === 'object' && 'definition' in (parsed as object)
      ? (parsed as { definition: unknown }).definition
      : parsed
  const result = validateDefinition(candidate as Definition)
  if (!result.ok || !result.definition) {
    throw new Error(
      result.issues.map((i) => `${i.path}: ${i.message}`).join('; ') || 'invalid_definition',
    )
  }
  return result.definition
}

export function parseAiCalculatorPatches(raw: string): CalculatorPatch[] {
  const parsed = JSON.parse(raw) as unknown
  const list =
    Array.isArray(parsed)
      ? parsed
      : parsed && typeof parsed === 'object' && Array.isArray((parsed as { patches?: unknown }).patches)
        ? (parsed as { patches: CalculatorPatch[] }).patches
        : null
  if (!list) throw new Error('invalid_patches')
  for (const p of list) {
    if (!p || typeof p !== 'object') throw new Error('invalid_patch')
    if (p.op !== 'add' && p.op !== 'replace' && p.op !== 'remove') throw new Error('bad_op')
    if (typeof p.path !== 'string' || !p.path.startsWith('/')) throw new Error('bad_path')
  }
  return list as CalculatorPatch[]
}

function unescapePointerToken(token: string): string {
  return token.replace(/~1/g, '/').replace(/~0/g, '~')
}

function applyOnePatch(root: unknown, patch: CalculatorPatch): unknown {
  const parts = patch.path.split('/').slice(1).map(unescapePointerToken)
  if (parts.length === 0) {
    if (patch.op === 'replace' || patch.op === 'add') return patch.value
    throw new Error('cannot_remove_root')
  }
  const clone = structuredClone(root) as Record<string, unknown> | unknown[]
  let cursor: unknown = clone
  for (let i = 0; i < parts.length - 1; i++) {
    const key = parts[i]!
    if (cursor == null || typeof cursor !== 'object') throw new Error(`missing:${key}`)
    cursor = Array.isArray(cursor)
      ? cursor[Number(key)]
      : (cursor as Record<string, unknown>)[key]
  }
  const last = parts[parts.length - 1]!
  if (cursor == null || typeof cursor !== 'object') throw new Error(`missing_parent:${last}`)
  if (Array.isArray(cursor)) {
    const idx = last === '-' ? cursor.length : Number(last)
    if (patch.op === 'remove') {
      cursor.splice(idx, 1)
    } else if (patch.op === 'add') {
      cursor.splice(idx, 0, patch.value)
    } else {
      cursor[idx] = patch.value
    }
  } else {
    const obj = cursor as Record<string, unknown>
    if (patch.op === 'remove') delete obj[last]
    else obj[last] = patch.value
  }
  return clone
}

/** Aplica el lot sencer o res. Valida el resultat. */
export function applyCalculatorPatches(
  definition: Definition,
  patches: CalculatorPatch[],
): Definition {
  let current: unknown = structuredClone(definition)
  for (const patch of patches) {
    current = applyOnePatch(current, patch)
  }
  const result = validateDefinition(current as Definition)
  if (!result.ok || !result.definition) {
    throw new Error(
      result.issues.map((i) => `${i.path}: ${i.message}`).join('; ') || 'invalid_after_patch',
    )
  }
  return result.definition
}

function stripJsonFences(raw: string): string {
  const trimmed = raw.trim()
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)```$/i)
  return fenced ? fenced[1].trim() : trimmed
}

function unwrapFragment(raw: string, kind: CalculatorFragmentKind): unknown {
  const parsed = JSON.parse(stripJsonFences(raw)) as unknown
  if (!parsed || typeof parsed !== 'object') throw new Error('invalid_fragment')
  const obj = parsed as Record<string, unknown>
  if (kind in obj) return obj[kind]
  if (kind === 'parameter' && 'parameters' in obj && Array.isArray(obj.parameters)) {
    return obj.parameters[0]
  }
  if (kind === 'constant' && 'constants' in obj && Array.isArray(obj.constants)) {
    return obj.constants[0]
  }
  if (kind === 'table' && 'tables' in obj && Array.isArray(obj.tables)) {
    return obj.tables[0]
  }
  if (kind === 'line' && 'lines' in obj && Array.isArray(obj.lines)) {
    return obj.lines[0]
  }
  return parsed
}

const PARAM_TYPES = new Set(['number', 'integer', 'money', 'boolean', 'enum'])
const CONST_TYPES = new Set(['number', 'money'])

/** Normalitza claus IA (Pes, Weight (kg), weightKg…) → snake_case vàlid. */
export function normalizeCalculatorKey(raw: unknown, fallback = 'item'): string {
  const source =
    typeof raw === 'string' && raw.trim()
      ? raw
      : typeof fallback === 'string'
        ? fallback
        : 'item'
  let key = source
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_|_$/g, '')
    .slice(0, 40)
  if (!key || !/^[a-z]/.test(key)) key = `p_${key || 'item'}`.slice(0, 40)
  if (!KEY_RE.test(key)) {
    key = `item_${Date.now().toString(36)}`.slice(0, 40)
  }
  return key
}

const GENERIC_PARAM_LABEL =
  /^(par[aà]metre|parameter|par[aá]metro|item|camp|field|entrada|input|valor)$/i
const GENERIC_PARAM_KEY =
  /^(parametre|parameter|parametro|param|item|p_item|field|input|valor)$/i

const PROMPT_STOPWORDS = new Set([
  'vull',
  'quiero',
  'want',
  'un',
  'una',
  'el',
  'la',
  'els',
  'les',
  'los',
  'las',
  'per',
  'para',
  'de',
  'del',
  'd',
  'a',
  'al',
  'en',
  'amb',
  'con',
  'i',
  'y',
  'o',
  'the',
  'an',
  'to',
  'for',
  'add',
  'create',
  'afegir',
  'crear',
  'entrar',
  'introduir',
  'introducir',
  'posar',
  'poner',
  'nou',
  'nuevo',
  'new',
  'parametre',
  'paràmetre',
  'parametro',
  'parámetro',
  'parameter',
  'camp',
  'campo',
  'field',
  'input',
])

const CONCEPT_HINTS: Array<{ re: RegExp; label: string; key: string; unit?: string }> = [
  { re: /\b(pes|peso|weight)\b/i, label: 'Pes', key: 'weight_kg', unit: 'kg' },
  {
    re: /\b(dist[aà]ncia|distancia|distance)\b/i,
    label: 'Distància',
    key: 'distance_km',
    unit: 'km',
  },
  {
    re: /\b(pot[eè]ncia|potencia|power)\b/i,
    label: 'Potència',
    key: 'power_kw',
    unit: 'kW',
  },
  { re: /\b(hores|horas|hours?)\b/i, label: 'Hores', key: 'hours', unit: 'h' },
  {
    re: /\b(amplada|ancho|width)\b/i,
    label: 'Amplada',
    key: 'width_cm',
    unit: 'cm',
  },
  {
    re: /\b(al[cç]ada|altura|height)\b/i,
    label: 'Alçada',
    key: 'height_cm',
    unit: 'cm',
  },
  {
    re: /\b(unitats|unidades|units?|qty|quantity|quantitat)\b/i,
    label: 'Unitats',
    key: 'units',
    unit: 'u',
  },
]

function capitalizeLabel(word: string): string {
  const clean = word.trim()
  if (!clean) return clean
  return clean.charAt(0).toUpperCase() + clean.slice(1).toLowerCase()
}

/** Extreu label/key/unit útils del prompt quan la IA retorna noms genèrics. */
export function inferParameterHintsFromPrompt(prompt: string): {
  label?: string
  key?: string
  unit?: string
} {
  const text = prompt.trim()
  if (!text) return {}
  for (const concept of CONCEPT_HINTS) {
    if (concept.re.test(text)) {
      return { label: concept.label, key: concept.key, unit: concept.unit }
    }
  }
  const words = text
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((w) => w.length >= 3 && !PROMPT_STOPWORDS.has(w))
  const last = words[words.length - 1]
  if (!last) return {}
  return {
    label: capitalizeLabel(last),
    key: normalizeCalculatorKey(last),
  }
}

function isGenericParamLabel(value: string | undefined | null): boolean {
  return !value?.trim() || GENERIC_PARAM_LABEL.test(value.trim())
}

function isGenericParamKey(value: string | undefined | null): boolean {
  return !value?.trim() || GENERIC_PARAM_KEY.test(value.trim())
}

function assertKey(raw: unknown, label: string, labelHint?: unknown): string {
  const hint =
    labelHint && typeof labelHint === 'object' && labelHint !== null && 'ca' in labelHint
      ? String((labelHint as { ca?: string }).ca ?? '')
      : typeof labelHint === 'string'
        ? labelHint
        : 'item'
  const key = normalizeCalculatorKey(raw, hint || 'item')
  if (!KEY_RE.test(key)) throw new Error(`${label}: clau tècnica invàlida`)
  return key
}

function buildParameterFromAiFragment(
  fragment: unknown,
  userPrompt?: string,
  existingKeys: string[] = [],
): Parameter {
  if (!fragment || typeof fragment !== 'object') throw new Error('invalid_fragment')
  const hints = inferParameterHintsFromPrompt(userPrompt ?? '')
  const rawP = fragment as Partial<Parameter>
  const rawLabel =
    rawP.label && typeof rawP.label === 'object'
      ? (rawP.label as Parameter['label'])
      : null
  let labelCa =
    rawLabel?.ca?.trim() ||
    rawLabel?.es?.trim() ||
    (typeof rawP.key === 'string' && rawP.key.trim() && !isGenericParamKey(rawP.key)
      ? rawP.key.trim()
      : '')
  if (isGenericParamLabel(labelCa) && hints.label) labelCa = hints.label
  if (!labelCa) labelCa = hints.label || 'Paràmetre'

  let keySource: unknown = rawP.key
  if (isGenericParamKey(typeof rawP.key === 'string' ? rawP.key : '')) {
    keySource = hints.key || labelCa
  }
  let key = assertKey(keySource, 'parameter', hints.key || labelCa)
  if (existingKeys.includes(key)) {
    let i = 2
    while (existingKeys.includes(`${key}_${i}`) && i < 50) i += 1
    key = `${key}_${i}`.slice(0, 40)
  }

  const typeRaw = String(rawP.type ?? 'number').trim().toLowerCase()
  const type = PARAM_TYPES.has(typeRaw) ? typeRaw : 'number'
  const unit =
    typeof rawP.unit === 'string' && rawP.unit.trim()
      ? rawP.unit.trim()
      : hints.unit

  return {
    key,
    type: type as Parameter['type'],
    required: rawP.required !== false,
    label: { ...(rawLabel ?? {}), ca: labelCa },
    min:
      typeof rawP.min === 'number'
        ? rawP.min
        : type === 'number' || type === 'integer'
          ? 0
          : undefined,
    max: typeof rawP.max === 'number' ? rawP.max : undefined,
    unit,
    options_from: typeof rawP.options_from === 'string' ? rawP.options_from : undefined,
    help: rawP.help && typeof rawP.help === 'object' ? rawP.help : undefined,
    default: rawP.default,
  }
}

/** Extreu un esborrany de paràmetre (per omplir el modal, sense crear-lo encara). */
export function parseAiParameterProposal(
  raw: string,
  userPrompt?: string,
  existingKeys: string[] = [],
): Parameter {
  const fragment = unwrapFragment(raw, 'parameter')
  return buildParameterFromAiFragment(fragment, userPrompt, existingKeys)
}

/** Fusiona un fragment IA (paràmetre/constant/taula/línia) a la definició. */
export function parseAiCalculatorFragment(
  raw: string,
  kind: CalculatorFragmentKind,
  definition: Definition,
  userPrompt?: string,
): Definition {
  const fragment = unwrapFragment(raw, kind)
  if (!fragment || typeof fragment !== 'object') throw new Error('invalid_fragment')
  const next = structuredClone(definition)
  next.parameters = next.parameters ?? []
  next.constants = next.constants ?? []
  next.tables = next.tables ?? []
  next.lines = next.lines ?? []

  if (kind === 'parameter') {
    const param = buildParameterFromAiFragment(
      fragment,
      userPrompt,
      next.parameters.map((p) => p.key),
    )
    next.parameters.push(param)
  } else if (kind === 'constant') {
    const rawC = fragment as Partial<Constant>
    const label =
      rawC.label && typeof rawC.label === 'object'
        ? (rawC.label as Constant['label'])
        : { ca: typeof rawC.key === 'string' && rawC.key.trim() ? rawC.key.trim() : 'Constant' }
    const key = assertKey(rawC.key, 'constant', label?.ca)
    const typeRaw = String(rawC.type ?? 'money').trim().toLowerCase()
    const type = CONST_TYPES.has(typeRaw) ? typeRaw : 'money'
    if (next.constants.some((x) => x.key === key)) throw new Error('duplicate_constant')
    const value =
      typeof rawC.value === 'number' && Number.isFinite(rawC.value) ? rawC.value : null
    next.constants.push({
      key,
      type: type as Constant['type'],
      value,
      assumed: value == null ? true : rawC.assumed,
      label,
    })
  } else if (kind === 'table') {
    const t = fragment as LookupTable
    const key = assertKey(t.key, 'table')
    if (next.tables.some((x) => x.key === key)) throw new Error('duplicate_table')
    if (!Array.isArray(t.rows)) throw new Error('table: cal rows[]')
    next.tables.push({ ...t, key })
  } else {
    const line = fragment as LineDef
    const key = assertKey(line.key, 'line', line.name?.ca)
    if (next.lines.some((x) => x.key === key)) throw new Error('duplicate_line')
    const unitCost =
      typeof line.unit_cost === 'number' && Number.isFinite(line.unit_cost)
        ? line.unit_cost
        : line.unit_cost === null
          ? null
          : undefined
    next.lines.push({
      ...line,
      key,
      prompt_qty_price: line.prompt_qty_price === true ? true : undefined,
      ...(unitCost !== undefined ? { unit_cost: unitCost } : {}),
    })
  }

  if (next.lines.length > 0) {
    const result = validateDefinition(next)
    if (!result.ok || !result.definition) {
      throw new Error(
        result.issues.map((i) => `${i.path}: ${i.message}`).join('; ') || 'invalid_after_fragment',
      )
    }
    return result.definition
  }
  return next
}

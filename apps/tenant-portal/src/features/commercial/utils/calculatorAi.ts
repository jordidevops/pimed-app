import {
  KEY_RE,
  validateDefinition,
  type Constant,
  type Definition,
  type LineDef,
  type LookupTable,
  type Parameter,
  type ParamValues,
} from '@pimed/price-calculator'

export type CalculatorFragmentKind = 'parameter' | 'constant' | 'table' | 'line'

export type CalculatorPatch = {
  op: 'add' | 'replace' | 'remove'
  path: string
  value?: unknown
}

export const CALCULATOR_AI_MAX_TURNS = 8
export const CALCULATOR_AI_MAX_QUESTIONS = 5

export type CalculatorAiScope = 'section' | 'full'

export type CalculatorAiClarifyQuestion = { id: string; prompt: string }

export type CalculatorAiClarify = {
  mode: 'clarify'
  assistant_message: string
  questions: CalculatorAiClarifyQuestion[]
}

export type CalculatorAiProposal = {
  mode: 'proposal'
  assistant_message: string
  summary: string
  draft: Definition | { patches: CalculatorPatch[] }
  example: { params: ParamValues }
}

export type CalculatorAiReady = {
  mode: 'ready'
  /** Objecte per parsers legacy (fragment / definition / patches). */
  payload: unknown
}

export type CalculatorAiEnvelope =
  | CalculatorAiClarify
  | CalculatorAiProposal
  | CalculatorAiReady

function stripJsonFences(raw: string): string {
  const trimmed = raw.trim()
  const fenced = /^```(?:json)?\s*([\s\S]*?)```$/i.exec(trimmed)
  return fenced ? fenced[1]!.trim() : trimmed
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

function parseClarify(
  obj: Record<string, unknown>,
  maxQuestions = CALCULATOR_AI_MAX_QUESTIONS,
): CalculatorAiClarify {
  const assistant_message =
    typeof obj.assistant_message === 'string' ? obj.assistant_message.trim() : ''
  const rawQs = Array.isArray(obj.questions) ? obj.questions : []
  const questions: CalculatorAiClarifyQuestion[] = []
  const cap = Math.min(maxQuestions, CALCULATOR_AI_MAX_QUESTIONS)
  for (let i = 0; i < rawQs.length && questions.length < cap; i++) {
    const q = rawQs[i]
    if (!isRecord(q)) continue
    const prompt = typeof q.prompt === 'string' ? q.prompt.trim() : ''
    if (!prompt) continue
    const id =
      typeof q.id === 'string' && q.id.trim() ? q.id.trim() : `q${questions.length + 1}`
    questions.push({ id, prompt })
  }
  if (questions.length === 0) {
    throw new Error('clarify: cal almenys una pregunta')
  }
  return {
    mode: 'clarify',
    assistant_message: assistant_message || 'Necessito més informació.',
    questions,
  }
}

function parseProposalDraft(draft: unknown, editMode: boolean): CalculatorAiProposal['draft'] {
  if (!draft || typeof draft !== 'object') throw new Error('proposal: draft obligatori')
  if (Array.isArray((draft as { patches?: unknown }).patches) || 'patches' in (draft as object)) {
    const patches = parseAiCalculatorPatches(JSON.stringify(draft))
    return { patches }
  }
  if (editMode && Array.isArray(draft)) {
    return { patches: parseAiCalculatorPatches(JSON.stringify(draft)) }
  }
  return parseAiCalculatorDefinition(JSON.stringify(draft))
}

function parseProposal(obj: Record<string, unknown>, editMode: boolean): CalculatorAiProposal {
  const assistant_message =
    typeof obj.assistant_message === 'string' ? obj.assistant_message.trim() : ''
  const summary = typeof obj.summary === 'string' ? obj.summary.trim() : ''
  if (!summary) throw new Error('proposal: summary obligatori')
  const draft = parseProposalDraft(obj.draft, editMode)
  const exampleRaw = obj.example
  if (!isRecord(exampleRaw) || !isRecord(exampleRaw.params)) {
    throw new Error('proposal: example.params obligatori')
  }
  return {
    mode: 'proposal',
    assistant_message: assistant_message || summary,
    summary,
    draft,
    example: { params: exampleRaw.params as ParamValues },
  }
}

function detectLegacyShape(parsed: unknown): CalculatorAiReady['payload'] | null {
  if (Array.isArray(parsed)) return { patches: parsed }
  if (!isRecord(parsed)) return null
  if (Array.isArray(parsed.patches)) return parsed
  if (parsed.schema_version === 1 || isRecord(parsed.definition)) return parsed
  for (const kind of ['parameter', 'constant', 'table', 'line'] as const) {
    if (kind in parsed) return parsed
  }
  return null
}

const FRAGMENT_KINDS: CalculatorFragmentKind[] = [
  'parameter',
  'constant',
  'table',
  'line',
]

function looksLikeFullDefinition(v: unknown): boolean {
  if (!isRecord(v)) return false
  if (v.schema_version === 1) return true
  return (
    Array.isArray(v.parameters) &&
    (Array.isArray(v.lines) || Array.isArray(v.tables) || Array.isArray(v.constants))
  )
}

function looksLikeConstant(v: unknown): boolean {
  if (!isRecord(v)) return false
  if (looksLikeFullDefinition(v)) return false
  if ('rows' in v || 'quantity' in v || 'unit_price' in v) return false
  if (Array.isArray(v.parameters) || Array.isArray(v.constants) || Array.isArray(v.lines)) {
    return false
  }
  const type = typeof v.type === 'string' ? v.type.toLowerCase() : ''
  if (type === 'money' || type === 'number' || type === 'percent' || type === 'boolean') {
    return true
  }
  return typeof v.key === 'string' && ('value' in v || isRecord(v.label))
}

function looksLikeParameter(v: unknown): boolean {
  if (!isRecord(v)) return false
  if (looksLikeFullDefinition(v) || looksLikeConstant(v)) return false
  if ('rows' in v || 'quantity' in v) return false
  const type = typeof v.type === 'string' ? v.type.toLowerCase() : ''
  return (
    typeof v.key === 'string' &&
    (type === 'number' ||
      type === 'integer' ||
      type === 'boolean' ||
      type === 'enum' ||
      type === 'string' ||
      type === 'date' ||
      isRecord(v.label))
  )
}

function fragmentPlural(kind: CalculatorFragmentKind): string {
  return kind === 'parameter'
    ? 'parameters'
    : kind === 'constant'
      ? 'constants'
      : kind === 'table'
        ? 'tables'
        : 'lines'
}

function scoreFragmentAgainstPrompt(item: unknown, prompt: string): number {
  if (!isRecord(item) || !prompt.trim()) return 0
  const blob = `${String(item.key ?? '')} ${JSON.stringify(item.label ?? {})}`.toLowerCase()
  const p = prompt.toLowerCase()
  let score = 0
  const tokens = [
    'benzina',
    'gasolina',
    'fuel',
    'diesel',
    'gasoil',
    'litre',
    'litro',
    '€/l',
    'eur_l',
    'km',
    'hora',
    'hour',
    'despes',
    'cotxe',
    'coche',
  ]
  for (const t of tokens) {
    if (p.includes(t) && blob.includes(t.replace('€/', 'eur_'))) score += 3
    if (p.includes(t) && blob.includes(t)) score += 3
  }
  if (/benzina|gasolina|fuel|diesel|gasoil/.test(p) && /fuel|benz|gasol|diesel|gasoil|eur_l|_l\b/.test(blob)) {
    score += 8
  }
  if (/hora|€\/h|eur_h|labor/.test(p) && /hora|hour|eur_h|labor/.test(blob)) score += 8
  return score
}

function pickFromArray(
  items: unknown[],
  userPrompt?: string,
): unknown | null {
  const usable = items.filter((x) => x && typeof x === 'object')
  if (usable.length === 0) return null
  if (usable.length === 1) return usable[0]!
  if (userPrompt?.trim()) {
    let best = usable[0]!
    let bestScore = scoreFragmentAgainstPrompt(best, userPrompt)
    for (let i = 1; i < usable.length; i++) {
      const s = scoreFragmentAgainstPrompt(usable[i], userPrompt)
      if (s >= bestScore) {
        best = usable[i]!
        bestScore = s
      }
    }
    if (bestScore > 0) return best
  }
  return usable[usable.length - 1]!
}

function explicitSectionFragment(
  obj: Record<string, unknown>,
  sectionKind?: CalculatorFragmentKind,
): CalculatorAiReady | null {
  const prefer = sectionKind
    ? [sectionKind, ...FRAGMENT_KINDS.filter((k) => k !== sectionKind)]
    : FRAGMENT_KINDS
  for (const kind of prefer) {
    if (kind in obj && obj[kind] != null && !Array.isArray(obj[kind])) {
      return { mode: 'ready', payload: { [kind]: obj[kind] } }
    }
  }
  return null
}

function deepCollectByKind(
  root: unknown,
  kind: CalculatorFragmentKind,
  out: unknown[],
  seen = new Set<unknown>(),
  depth = 0,
): void {
  if (depth > 10 || root == null) return
  if (typeof root === 'object') {
    if (seen.has(root)) return
    seen.add(root)
  }
  if (kind === 'constant' && looksLikeConstant(root)) {
    out.push(root)
    return
  }
  if (kind === 'parameter' && looksLikeParameter(root)) {
    out.push(root)
    return
  }
  if (Array.isArray(root)) {
    for (const item of root) deepCollectByKind(item, kind, out, seen, depth + 1)
    return
  }
  if (!isRecord(root)) return
  const plural = fragmentPlural(kind)
  if (Array.isArray(root[plural])) {
    for (const item of root[plural] as unknown[]) {
      if (item && typeof item === 'object') out.push(item)
    }
  }
  // Alias freqüents del model
  for (const alt of ['fragment', 'item', 'data', 'result', 'output', 'payload', 'value']) {
    if (isRecord(root[alt])) deepCollectByKind(root[alt], kind, out, seen, depth + 1)
  }
  for (const val of Object.values(root)) {
    deepCollectByKind(val, kind, out, seen, depth + 1)
  }
}

/**
 * Fallback de key/label quan la IA no torna fragment útil.
 * No inventa preus: el valor l’ha de posar la IA via system prompt (assumed).
 */
export function synthesizeConstantFromPrompt(userPrompt: string): Constant {
  const p = userPrompt.toLowerCase()
  if (/benzina|gasolina|fuel|diesel|gasoil/.test(p)) {
    return {
      key: 'fuel_eur_l',
      type: 'money',
      value: null,
      assumed: true,
      label: { ca: '€/l benzina' },
    }
  }
  if (/€\s*\/\s*h|eur\s*\/?\s*h|hora|mà d['’]obra|mano de obra|labor/.test(p)) {
    return {
      key: 'labor_eur_h',
      type: 'money',
      value: null,
      assumed: true,
      label: { ca: '€/hora' },
    }
  }
  if (/€\s*\/\s*km|eur\s*\/?\s*km|km|despla[cç]|kil[oó]metr/.test(p)) {
    return {
      key: 'travel_eur_km',
      type: 'money',
      value: null,
      assumed: true,
      label: { ca: '€/km' },
    }
  }
  const key = normalizeCalculatorKey(userPrompt, 'tariff_eur').slice(0, 40)
  return {
    key: KEY_RE.test(key) ? key : 'tariff_eur',
    type: 'money',
    value: null,
    assumed: true,
    label: { ca: 'Tarifa' },
  }
}

/** Extreu el fragment demanat des de proposal/ready mal formats. */
function extractSectionFragment(
  obj: Record<string, unknown>,
  sectionKind?: CalculatorFragmentKind,
  userPrompt?: string,
): CalculatorAiReady | null {
  const kind = sectionKind ?? 'constant'

  const explicit = explicitSectionFragment(obj, kind)
  if (explicit) return explicit

  if (kind === 'constant' && looksLikeConstant(obj)) {
    return { mode: 'ready', payload: { constant: obj } }
  }
  if (kind === 'parameter' && looksLikeParameter(obj)) {
    return { mode: 'ready', payload: { parameter: obj } }
  }

  const plural = fragmentPlural(kind)
  if (Array.isArray(obj[plural])) {
    const picked = pickFromArray(obj[plural] as unknown[], userPrompt)
    if (picked) return { mode: 'ready', payload: { [kind]: picked } }
  }

  if (isRecord(obj.definition)) {
    const nested = extractSectionFragment(obj.definition, kind, userPrompt)
    if (nested) return nested
  }

  const draftVal = obj.draft
  if (typeof draftVal === 'string') {
    try {
      const inner = JSON.parse(draftVal) as unknown
      if (isRecord(inner)) {
        const nested = extractSectionFragment(inner, kind, userPrompt)
        if (nested) return nested
      }
    } catch {
      /* ignore */
    }
  } else if (isRecord(draftVal)) {
    const nested = extractSectionFragment(draftVal, kind, userPrompt)
    if (nested) return nested
  }

  const deep: unknown[] = []
  deepCollectByKind(obj, kind, deep)
  const pickedDeep = pickFromArray(deep, userPrompt)
  if (pickedDeep) return { mode: 'ready', payload: { [kind]: pickedDeep } }

  return null
}

/**
 * Extreu un fragment de secció d’un proposal mal format (incl. Definition amb constants[]).
 * Per constants, si no hi ha res aprofitable → sintetitza des del prompt (no bloqueja l’usuari).
 */
function coerceSectionReadyFromProposal(
  parsed: Record<string, unknown>,
  sectionKind?: CalculatorFragmentKind,
  userPrompt?: string,
): CalculatorAiReady | null {
  const extracted = extractSectionFragment(parsed, sectionKind, userPrompt)
  if (extracted) return extracted
  if (sectionKind === 'constant' && userPrompt?.trim()) {
    return {
      mode: 'ready',
      payload: { constant: synthesizeConstantFromPrompt(userPrompt) },
    }
  }
  return null
}

/** Payload ready de secció: fragment explícit o extracció des de Definition. */
function sectionReadyPayload(
  payload: unknown,
  sectionKind?: CalculatorFragmentKind,
  userPrompt?: string,
): unknown {
  if (!isRecord(payload)) throw new Error('ready: payload invàlid')
  const extracted = extractSectionFragment(payload, sectionKind, userPrompt)
  if (extracted) return extracted.payload
  if (sectionKind === 'constant' && userPrompt?.trim()) {
    return { constant: synthesizeConstantFromPrompt(userPrompt) }
  }
  if (looksLikeFullDefinition(payload)) {
    throw new Error(
      'La IA ha retornat una calculadora sencera sense el fragment demanat. Torna a enviar.',
    )
  }
  return payload
}

/**
 * Parseja la resposta multi-torn de la IA de calculadores.
 * Compat: JSON legacy sense `mode` → ready (section) o proposal (full).
 */
export function parseCalculatorAiEnvelope(
  raw: string,
  opts: {
    scope: CalculatorAiScope
    editMode?: boolean
    sectionKind?: CalculatorFragmentKind
    userPrompt?: string
  },
): CalculatorAiEnvelope {
  const parsed = JSON.parse(stripJsonFences(raw)) as unknown
  if (!isRecord(parsed)) throw new Error('invalid_envelope')

  const modeRaw = typeof parsed.mode === 'string' ? parsed.mode.trim().toLowerCase() : null
  const mode = modeRaw
  const editMode = !!opts.editMode

  if (mode === 'clarify') {
    const maxQ =
      opts.scope === 'section' &&
      (opts.sectionKind === 'parameter' || opts.sectionKind === 'constant')
        ? 2
        : CALCULATOR_AI_MAX_QUESTIONS
    return parseClarify(parsed, maxQ)
  }

  if (mode === 'proposal') {
    if (opts.scope === 'section') {
      const coerced = coerceSectionReadyFromProposal(
        parsed,
        opts.sectionKind,
        opts.userPrompt,
      )
      if (coerced) return coerced
      throw new Error(
        'La IA no ha tornat un fragment vàlid. Torna a enviar (ex.: una sola constant amb key/label/value).',
      )
    }
    return parseProposal(parsed, editMode)
  }

  if (mode === 'ready') {
    const { mode: _m, ...rest } = parsed
    const payload = Object.keys(rest).length ? rest : parsed
    if (opts.scope === 'full') {
      // Full no aplica sols: coerce a proposal si hi ha draft/definició/patches
      if ('draft' in parsed) {
        const withExample =
          isRecord(parsed.example) && isRecord(parsed.example.params)
            ? parsed
            : { ...parsed, example: { params: {} } }
        return parseProposal(withExample, editMode)
      }
      const legacy = detectLegacyShape(payload)
      if (!legacy) throw new Error('full: ready sense draft')
      if (isRecord(legacy) && Array.isArray(legacy.patches)) {
        return {
          mode: 'proposal',
          assistant_message: 'Proposta de canvis',
          summary: 'Canvis proposats (diff)',
          draft: { patches: parseAiCalculatorPatches(JSON.stringify(legacy)) },
          example: { params: {} },
        }
      }
      const definition = parseAiCalculatorDefinition(JSON.stringify(legacy))
      return {
        mode: 'proposal',
        assistant_message: 'Proposta de definició',
        summary: 'Definició proposada',
        draft: definition,
        example: { params: {} },
      }
    }
    if (opts.scope === 'section') {
      return {
        mode: 'ready',
        payload: sectionReadyPayload(payload, opts.sectionKind, opts.userPrompt),
      }
    }
    return { mode: 'ready', payload }
  }

  // Legacy sense mode
  const legacy = detectLegacyShape(parsed)
  if (!legacy) throw new Error('envelope desconegut')

  if (opts.scope === 'full') {
    if (isRecord(legacy) && Array.isArray(legacy.patches)) {
      return {
        mode: 'proposal',
        assistant_message: 'Proposta de canvis',
        summary: 'Canvis proposats (diff)',
        draft: { patches: parseAiCalculatorPatches(JSON.stringify(legacy)) },
        example: { params: {} },
      }
    }
    return {
      mode: 'proposal',
      assistant_message: 'Proposta de definició',
      summary: 'Definició proposada',
      draft: parseAiCalculatorDefinition(JSON.stringify(legacy)),
      example: { params: {} },
    }
  }

  return {
    mode: 'ready',
    payload: sectionReadyPayload(legacy, opts.sectionKind, opts.userPrompt),
  }
}

export function isPatchesDraft(
  draft: CalculatorAiProposal['draft'],
): draft is { patches: CalculatorPatch[] } {
  return isRecord(draft) && Array.isArray((draft as { patches?: unknown }).patches)
}

/** System prompt d’envelope per seccions. */
export function calculatorAiSectionSystemPrompt(
  kind: CalculatorFragmentKind,
  fragmentHint: string,
): string {
  const clarifyRule =
    kind === 'parameter'
      ? [
          'Prefereix SEMPRE ready si pots inferir key/label/type.',
          'clarify NOMÉS si falta un fet imprescindible (màx 1–2 preguntes).',
          'NO preguntis unit, min, max, required, help ni opcions.',
        ].join(' ')
      : kind === 'constant'
        ? [
            'Prefereix SEMPRE ready amb key, label i value numèric.',
            'Si l’usuari NO diu el preu: estima un valor raonable de mercat per al context (país ES si no es diu el contrari) i marca assumed:true.',
            'Si diu el preu: usa exactament aquesta xifra i assumed:false o omet assumed.',
            'clarify NOMÉS si és ambigu què tarifar (màx 1 pregunta). No preguntis el preu si pots estimar.',
          ].join(' ')
        : [
            'Prefereix ready quan la demanda és prou clara; omple amb defaults raonables.',
            'clarify només si falta un fet imprescindible (màx 2 preguntes).',
          ].join(' ')

  return [
    'Retorna NOMÉS JSON (sense markdown) amb envelope multi-torn.',
    'Modes permesos: clarify | ready. NO usis mode proposal ni Definition completa.',
    'clarify: {"mode":"clarify","assistant_message":"...","questions":[{"id":"q1","prompt":"..."}]}',
    `ready: {"mode":"ready", ...UN SOL fragment}. Payload: ${fragmentHint}`,
    `Només la clau ${kind}. Sense parameters[]/tables[]/lines[] ni schema_version.`,
    clarifyRule,
  ].join(' ')
}

/** System prompt d’envelope per calculadora sencera. */
export function calculatorAiFullSystemPrompt(editMode: boolean): string {
  if (editMode) {
    return [
      'Retorna NOMÉS JSON envelope multi-torn (sense markdown).',
      'Modes: clarify | proposal. NO usis mode ready (el client només aplica amb botó).',
      'clarify: {"mode":"clarify","assistant_message":"...","questions":[{"id":"q1","prompt":"..."}]}',
      'proposal: {"mode":"proposal","assistant_message":"...","summary":"...","draft":{"patches":[...]},"example":{"params":{...}}}',
      'draft.patches: JSON Pointer ops add|replace|remove. example.params: escenari de prova.',
      'No inventis preus no dits. Sense eval ni claus desconegudes.',
    ].join(' ')
  }
  return [
    'Retorna NOMÉS JSON envelope multi-torn (sense markdown).',
    'Modes: clarify | proposal. NO usis mode ready.',
    'clarify: {"mode":"clarify","assistant_message":"...","questions":[{"id":"q1","prompt":"..."}]}',
    'proposal: {"mode":"proposal","assistant_message":"...","summary":"...","draft":{Definition schema_version=1},"example":{"params":{...}}}',
    'draft ha de ser Definition vàlida (parameters, lines, Expr AST). example.params per previsualitzar.',
    'prompt_qty_price / unit_cost permesos a lines. No inventis preus: null + assumed.',
  ].join(' ')
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

/**
 * Demote només d’una constant nova.
 * Si la xifra no és al prompt: es conserva el valor de la IA amb assumed:true
 * (el system prompt demana estimació; el client no inventa preus hardcoded).
 */
export function demoteUnconfirmedConstant(
  constant: Constant,
  userPrompt: string,
): Constant {
  const mentioned = extractMentionedNumbers(userPrompt)
  if (typeof constant.value === 'number' && Number.isFinite(constant.value)) {
    if (isMentioned(constant.value, mentioned)) {
      return { ...constant, assumed: false }
    }
    return { ...constant, assumed: true }
  }
  return { ...constant, value: null, assumed: true }
}

/** Demote només d’una taula nova. */
export function demoteUnconfirmedTable(
  table: LookupTable,
  userPrompt: string,
): LookupTable {
  const mentioned = extractMentionedNumbers(userPrompt)
  const next = structuredClone(table)
  for (const row of next.rows) {
    for (const [key, val] of Object.entries(row)) {
      if (key === 'id' || key === 'label' || key === 'assumed') continue
      if (!/eur|price|pct|amount|tariff|rate/i.test(key)) continue
      if (typeof val === 'number' && !isMentioned(val, mentioned)) {
        row[key] = null
        row.assumed = true
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

function unwrapFragment(raw: string, kind: CalculatorFragmentKind): unknown {
  const parsed = JSON.parse(stripJsonFences(raw)) as unknown
  if (!parsed || typeof parsed !== 'object') throw new Error('invalid_fragment')
  const obj = parsed as Record<string, unknown>
  if (kind in obj) {
    const frag = obj[kind]
    if (looksLikeFullDefinition(frag)) throw new Error('invalid_fragment')
    return frag
  }
  if (looksLikeFullDefinition(obj)) {
    throw new Error(
      'La IA ha retornat una calculadora sencera en lloc d’un sol fragment.',
    )
  }
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

const GENERIC_CONST_LABEL =
  /^(constant|constante|tarifa|tariff|item|valor|preu|precio|price|rate)$/i
const GENERIC_CONST_KEY =
  /^(constant|constante|const|tarifa|tariff|item|valor|preu|precio|price|rate|c_item)$/i

function isGenericConstLabel(value: string | undefined | null): boolean {
  return !value?.trim() || GENERIC_CONST_LABEL.test(value.trim())
}

function isGenericConstKey(value: string | undefined | null): boolean {
  return !value?.trim() || GENERIC_CONST_KEY.test(value.trim())
}

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

function buildConstantFromAiFragment(
  fragment: unknown,
  userPrompt?: string,
  existingKeys: string[] = [],
): Constant {
  if (!fragment || typeof fragment !== 'object') throw new Error('invalid_constant_fragment')
  const rawC = fragment as Partial<Constant>
  if (looksLikeFullDefinition(rawC) || Array.isArray((rawC as { parameters?: unknown }).parameters)) {
    throw new Error('invalid_constant_fragment')
  }
  const hints = userPrompt?.trim() ? synthesizeConstantFromPrompt(userPrompt) : null
  const rawLabel =
    rawC.label && typeof rawC.label === 'object'
      ? (rawC.label as Constant['label'])
      : null
  let labelCa =
    rawLabel?.ca?.trim() ||
    rawLabel?.es?.trim() ||
    (typeof rawC.key === 'string' && rawC.key.trim() && !isGenericConstKey(rawC.key)
      ? rawC.key.trim()
      : '')
  if (isGenericConstLabel(labelCa) && hints?.label) {
    labelCa = resolveLocaleLabel(hints.label) || hints.key
  }
  if (!labelCa) labelCa = hints ? resolveLocaleLabel(hints.label) || hints.key : 'Tarifa'

  let keySource: unknown = rawC.key
  if (isGenericConstKey(typeof rawC.key === 'string' ? rawC.key : '')) {
    keySource = hints?.key || labelCa
  }
  let key = assertKey(keySource, 'constant', hints?.key || labelCa)
  if (existingKeys.includes(key)) {
    let i = 2
    while (existingKeys.includes(`${key}_${i}`) && i < 50) i += 1
    key = `${key}_${i}`.slice(0, 40)
  }
  const typeRaw = String(rawC.type ?? hints?.type ?? 'money').trim().toLowerCase()
  const type = CONST_TYPES.has(typeRaw) ? typeRaw : 'money'
  const value =
    typeof rawC.value === 'number' && Number.isFinite(rawC.value) ? rawC.value : null
  let constant: Constant = {
    key,
    type: type as Constant['type'],
    value,
    assumed: value == null ? true : rawC.assumed,
    label: { ...(rawLabel ?? {}), ca: labelCa },
  }
  if (userPrompt) constant = demoteUnconfirmedConstant(constant, userPrompt)
  return constant
}

function resolveLocaleLabel(label: Constant['label'] | undefined): string {
  if (!label || typeof label !== 'object') return ''
  return label.ca?.trim() || label.es?.trim() || label.en?.trim() || ''
}

/** Extreu un esborrany de constant (per omplir el modal, sense crear-la encara). */
export function parseAiConstantProposal(
  raw: string,
  userPrompt?: string,
  existingKeys: string[] = [],
): Constant {
  const fragment = unwrapFragment(raw, 'constant')
  return buildConstantFromAiFragment(fragment, userPrompt, existingKeys)
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
    const constant = buildConstantFromAiFragment(
      fragment,
      userPrompt,
      next.constants.map((c) => c.key),
    )
    if (next.constants.some((x) => x.key === constant.key)) throw new Error('duplicate_constant')
    next.constants.push(constant)
  } else if (kind === 'table') {
    const t = fragment as LookupTable
    const key = assertKey(t.key, 'table')
    if (next.tables.some((x) => x.key === key)) throw new Error('duplicate_table')
    if (!Array.isArray(t.rows)) throw new Error('table: cal rows[]')
    let table: LookupTable = { ...t, key }
    if (userPrompt) table = demoteUnconfirmedTable(table, userPrompt)
    next.tables.push(table)
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

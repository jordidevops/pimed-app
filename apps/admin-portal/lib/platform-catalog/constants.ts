/**
 * Pure (client-safe) vocabulary and helpers shared by the platform catalog
 * server actions and their admin panels. Keep this module free of server-only
 * imports so client components can reuse the enums.
 */

export const CHECKLIST_LOCALES = ['ca', 'es', 'en'] as const
export type ChecklistLocale = (typeof CHECKLIST_LOCALES)[number]

export const CHECKLIST_LOCALE_LABELS: Record<ChecklistLocale, string> = {
  ca: 'Català',
  es: 'Castellà',
  en: 'Anglès',
}

export const CHECKLIST_ARCHETYPES = [
  'field_service',
  'practice',
  'hospitality',
  'workshop_maker',
  'generic',
] as const
export type ChecklistArchetype = (typeof CHECKLIST_ARCHETYPES)[number]

export const CHECKLIST_ARCHETYPE_LABELS: Record<ChecklistArchetype, string> = {
  field_service: 'Servei de camp',
  practice: 'Consulta / despatx',
  hospitality: 'Hostaleria',
  workshop_maker: 'Taller',
  generic: 'Genèric',
}

export const CHECKLIST_KINDS = ['todo', 'review'] as const
export type ChecklistKind = (typeof CHECKLIST_KINDS)[number]

export const CHECKLIST_KIND_LABELS: Record<ChecklistKind, string> = {
  todo: 'Llista de tasques',
  review: 'Revisió',
}

export const CHECKLIST_RESPONSE_TYPES = ['checkbox', 'single_choice'] as const
export type ChecklistResponseType = (typeof CHECKLIST_RESPONSE_TYPES)[number]

export const CHECKLIST_RESPONSE_TYPE_LABELS: Record<ChecklistResponseType, string> = {
  checkbox: 'Casella',
  single_choice: 'Opció única',
}

export const CHECKLIST_ANSWER_SEMANTICS = [
  'pass',
  'warning',
  'fail',
  'na',
  'neutral',
] as const
export type ChecklistAnswerSemantic = (typeof CHECKLIST_ANSWER_SEMANTICS)[number]

export const CHECKLIST_ANSWER_SEMANTIC_LABELS: Record<ChecklistAnswerSemantic, string> = {
  pass: 'OK (pass)',
  warning: 'Avís (warning)',
  fail: 'No conforme (fail)',
  na: 'No aplica (na)',
  neutral: 'Neutre',
}

export const CHECKLIST_ANSWER_SEMANTIC_HINTS: Record<ChecklistAnswerSemantic, string> = {
  pass: 'Resultat correcte. No bloqueja el tancament de la visita.',
  warning: 'Avís informatiu. Per defecte no bloqueja el tancament.',
  fail: 'Troballa / no conforme. Avui bloqueja el tancament de la visita.',
  na: 'Punt no aplicable. No bloqueja.',
  neutral: 'Sense significat de qualitat especial.',
}

export const CHECKLIST_COLOR_TOKENS = [
  'green',
  'yellow',
  'orange',
  'red',
  'neutral',
] as const
export type ChecklistColorToken = (typeof CHECKLIST_COLOR_TOKENS)[number]

export const MAINTENANCE_FREQUENCIES = ['daily', 'weekly', 'monthly', 'yearly'] as const
export type MaintenanceFrequency = (typeof MAINTENANCE_FREQUENCIES)[number]

export const MAINTENANCE_FREQUENCY_LABELS: Record<MaintenanceFrequency, string> = {
  daily: 'Diari',
  weekly: 'Setmanal',
  monthly: 'Mensual',
  yearly: 'Anual',
}

export const DEFAULT_TIMEZONE = 'Europe/Madrid'

export const DEFAULT_PAGE_SIZE = 20
export const MAX_PAGE_SIZE = 100

export interface PagedResult<T> {
  rows: T[]
  total: number
  page: number
  pageSize: number
  pageCount: number
}

export interface CatalogFilters {
  search?: string
  locale?: string
  category?: string
  vertical?: string
  archetype?: string
  includeArchived?: boolean
  page?: number
  pageSize?: number
}

export interface ActionResult {
  ok: boolean
  message: string
}

export function resolvePaging(page?: number, pageSize?: number) {
  const size = Math.max(1, Math.min(MAX_PAGE_SIZE, Math.floor(pageSize ?? DEFAULT_PAGE_SIZE)))
  const current = Math.max(1, Math.floor(page ?? 1))
  const from = (current - 1) * size
  return { page: current, size, from, to: from + size - 1 }
}

export function pageCount(total: number, pageSize: number): number {
  return Math.max(1, Math.ceil(total / Math.max(1, pageSize)))
}

/** PostgREST `or=` treats commas and parentheses as separators. */
export function sanitizeSearch(value: string | undefined | null): string {
  return (value ?? '').replace(/[,()]/g, ' ').trim()
}

/** Mirrors the database trigger that lowercases category/vertical. */
export function normalizeTaxonomy(value: string | undefined | null, fallback: string): string {
  const normalized = (value ?? '').trim().toLowerCase()
  return normalized || fallback
}

export function assertLocale(value: string | undefined | null): ChecklistLocale {
  const locale = (value ?? 'ca').trim() as ChecklistLocale
  if (!CHECKLIST_LOCALES.includes(locale)) throw new Error(`Idioma no vàlid: ${value}`)
  return locale
}

export function assertArchetype(value: string | undefined | null): ChecklistArchetype {
  const archetype = (value ?? 'generic').trim() as ChecklistArchetype
  if (!CHECKLIST_ARCHETYPES.includes(archetype)) throw new Error(`Arquetip no vàlid: ${value}`)
  return archetype
}

export function assertKind(value: string | undefined | null): ChecklistKind {
  const kind = (value ?? 'todo').trim() as ChecklistKind
  if (!CHECKLIST_KINDS.includes(kind)) throw new Error(`Tipus de plantilla no vàlid: ${value}`)
  return kind
}

export function assertAnswerSemantic(
  value: string | undefined | null,
): ChecklistAnswerSemantic {
  const semantic = (value ?? 'neutral').trim() as ChecklistAnswerSemantic
  if (!CHECKLIST_ANSWER_SEMANTICS.includes(semantic)) {
    throw new Error(`Semàntica no vàlida: ${value}`)
  }
  return semantic
}

export function assertFrequency(value: string | undefined | null): MaintenanceFrequency {
  const frequency = (value ?? 'monthly').trim() as MaintenanceFrequency
  if (!MAINTENANCE_FREQUENCIES.includes(frequency)) {
    throw new Error(`Freqüència no vàlida: ${value}`)
  }
  return frequency
}

export function asRecord(raw: unknown): Record<string, unknown> {
  return (raw ?? {}) as Record<string, unknown>
}

export function str(raw: unknown, fallback = ''): string {
  return raw != null ? String(raw) : fallback
}

export function nullableStr(raw: unknown): string | null {
  return raw != null ? String(raw) : null
}

export function num(raw: unknown, fallback = 0): number {
  const parsed = Number(raw)
  return Number.isFinite(parsed) ? parsed : fallback
}

/** Turns a Postgres error into a message the admin UI can show as-is. */
export function describeDbError(error: { message?: string; code?: string } | null): string {
  if (!error) return 'Error desconegut'
  const known: Record<string, string> = {
    version_has_no_items: 'No es pot publicar una versió sense punts.',
    version_not_draft: 'Aquesta versió ja no és un esborrany.',
    review_version_requires_response_set:
      'Les plantilles de revisió necessiten un conjunt de respostes per defecte o per punt.',
    platform_template_requires_service_role:
      'Aquesta operació requereix el client de servei de la plataforma.',
    template_not_found: 'Plantilla no trobada.',
    plan_not_found: 'Pla no trobat.',
  }
  const raw = error.message ?? ''
  for (const [key, friendly] of Object.entries(known)) {
    if (raw.includes(key)) return friendly
  }
  return raw || 'Error desconegut'
}

/** Compact human summary of a plan's default periodicity. */
export function describePeriodicity(plan: {
  frequency: string
  interval_count: number
  lead_days: number
}): string {
  const label =
    MAINTENANCE_FREQUENCY_LABELS[plan.frequency as MaintenanceFrequency] ?? plan.frequency
  const base = plan.interval_count > 1 ? `Cada ${plan.interval_count} · ${label}` : label
  return plan.lead_days > 0 ? `${base} · avís ${plan.lead_days}d` : base
}

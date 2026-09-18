/**
 * Canonical commercial full-body template context (QT-2).
 * Keep in sync with supabase/functions/_shared/commercial-document-context.ts
 *
 * Frozen contract: docs/plans/commercial-templates/01-context-and-legal-content.md §1 / §1.3
 */

export const COMMERCIAL_LEGAL_RETENTION_DAYS = 180

export type CommercialTemplateParty = Record<string, unknown>
export type CommercialTemplateAddress = Record<string, unknown>

export type CommercialTemplateLine = {
  name: string
  description?: string | null
  unit?: string | null
  quantity?: number | string | null
  unit_price?: number | string | null
  discount_pct?: number | string | null
  tax_rate?: number | string | null
  line_subtotal?: number | string | null
  line_total?: number | string | null
  kind?: string | null
}

export type CommercialTemplateDoc = {
  doc_type: string
  doc_number?: string | null
  status?: string | null
  locale?: string | null
  currency?: string | null
  issued_at?: string | null
  valid_until?: string | null
  created_at?: string | null
  show_prices?: boolean | null
  terms_text?: string | null
  seller_snapshot?: CommercialTemplateParty | null
  buyer_snapshot?: CommercialTemplateParty | null
  service_address_snapshot?: CommercialTemplateAddress | null
  subtotal?: number | string | null
  tax_breakdown?: unknown
  total?: number | string | null
}

export type CommercialTemplateTenant = {
  name?: string | null
  tax_id?: string | null
  address?: string | null
  phone?: string | null
  email?: string | null
  logo_url?: string | null
}

export const DEFAULT_COMMERCIAL_DATE_FORMAT = 'dd/MM/yyyy'
export const DEFAULT_COMMERCIAL_TIME_FORMAT = 'HH:mm'

export type CommercialDateFormats = {
  dateFormat: string
  timeFormat: string
}

export type BuildCommercialTemplateContextInput = {
  doc: CommercialTemplateDoc
  lines: CommercialTemplateLine[]
  tenant: CommercialTemplateTenant
  logoUrl?: string | null
  parentDocNumber?: string | null
  now?: Date
  dateFormat?: string | null
  timeFormat?: string | null
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

function str(value: unknown): string | null {
  if (value == null) return null
  const s = String(value).trim()
  return s.length > 0 ? s : null
}

export function commercialDisplayTimeZone(locale: string | null | undefined): string {
  const lang = (locale || 'ca').toLowerCase().slice(0, 2)
  return lang === 'en' ? 'Europe/London' : 'Europe/Madrid'
}

export function parseCommercialDateFormats(
  settings: Record<string, unknown> | null | undefined,
): CommercialDateFormats {
  return {
    dateFormat: str(settings?.default_date_format) ?? DEFAULT_COMMERCIAL_DATE_FORMAT,
    timeFormat: str(settings?.default_time_format) ?? DEFAULT_COMMERCIAL_TIME_FORMAT,
  }
}

function zonedDateParts(
  iso: string,
  timeZone: string,
): { yyyy: string; MM: string; dd: string; HH: string; mm: string } | null {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return null
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  })
  const parts = Object.fromEntries(fmt.formatToParts(date).map((p) => [p.type, p.value]))
  const yyyy = parts.year
  const MM = parts.month
  const dd = parts.day
  const HH = parts.hour
  const mm = parts.minute
  if (!yyyy || !MM || !dd || !HH || !mm) return null
  return { yyyy, MM, dd, HH, mm }
}

function applyDatePattern(parts: { yyyy: string; MM: string; dd: string }, pattern: string): string {
  return pattern.replace(/yyyy/g, parts.yyyy).replace(/MM/g, parts.MM).replace(/dd/g, parts.dd)
}

function applyTimePattern(parts: { HH: string; mm: string }, pattern: string): string {
  return pattern.replace(/HH/g, parts.HH).replace(/mm/g, parts.mm)
}

/** Date-only presentation (valid_until). ISO context fields stay untouched. */
export function formatCommercialDisplayDate(
  iso: string | null | undefined,
  locale: string | null | undefined,
  dateFormat: string | null | undefined,
): string | null {
  const raw = str(iso)
  if (!raw) return null
  const parts = zonedDateParts(raw, commercialDisplayTimeZone(locale))
  if (!parts) return raw
  return applyDatePattern(parts, str(dateFormat) ?? DEFAULT_COMMERCIAL_DATE_FORMAT)
}

/** Date + time presentation (issued_at / created_at). */
export function formatCommercialDisplayDateTime(
  iso: string | null | undefined,
  locale: string | null | undefined,
  dateFormat: string | null | undefined,
  timeFormat: string | null | undefined,
): string | null {
  const raw = str(iso)
  if (!raw) return null
  const parts = zonedDateParts(raw, commercialDisplayTimeZone(locale))
  if (!parts) return raw
  const date = applyDatePattern(parts, str(dateFormat) ?? DEFAULT_COMMERCIAL_DATE_FORMAT)
  const time = applyTimePattern(parts, str(timeFormat) ?? DEFAULT_COMMERCIAL_TIME_FORMAT)
  return `${date} ${time}`
}

function num(value: unknown): number | null {
  if (value == null || value === '') return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function partyName(party: Record<string, unknown>): string | null {
  return str(party.display_name) ?? str(party.legal_name) ?? str(party.name)
}

function partyFields(party: Record<string, unknown>): Record<string, string | null> {
  return {
    display_name: partyName(party),
    tax_id: str(party.tax_id),
    email: str(party.email),
    phone: str(party.phone),
    address_line1: str(party.address_line1),
    address_line2: str(party.address_line2),
    city: str(party.city),
    postal_code: str(party.postal_code),
  }
}

function serviceAddress(raw: Record<string, unknown>): Record<string, string | null> {
  const street = str(raw.street)
  const streetNumber = str(raw.street_number)
  const fromStreet = [street, streetNumber].filter(Boolean).join(' ')
  const line1 = fromStreet || str(raw.address) || str(raw.line1)
  return {
    label: str(raw.name) ?? str(raw.label),
    line1: line1 || null,
    line2: str(raw.line2),
    city: str(raw.city),
    postal_code: str(raw.postal_code),
    region: str(raw.province) ?? str(raw.region),
    country: str(raw.country_code) ?? str(raw.country),
  }
}

function taxBreakdown(
  raw: unknown,
  lines: CommercialTemplateLine[],
): Array<{ tax_rate: number | null; tax_amount: number | null; tax_base: number | null }> {
  const derived = new Map<number, number>()
  for (const line of lines) {
    const rate = num(line.tax_rate)
    const base = num(line.line_subtotal)
    if (rate == null || base == null) continue
    derived.set(rate, (derived.get(rate) ?? 0) + base)
  }
  if (!Array.isArray(raw)) return []
  return raw.map((row) => {
    const rec = asRecord(row)
    const tax_rate = num(rec.tax_rate)
    const stored = num(rec.tax_base)
    return {
      tax_rate,
      tax_amount: num(rec.tax_amount),
      tax_base: stored ?? (tax_rate == null ? null : derived.get(tax_rate) ?? null),
    }
  })
}

export function shouldUseFullBodyHtml(
  locale: { template_type?: string | null; html_content?: string | null } | null | undefined,
): boolean {
  return Boolean(
    locale &&
      locale.template_type === 'html' &&
      typeof locale.html_content === 'string' &&
      locale.html_content.length > 0,
  )
}

export function shouldUseFullBodyDocx(
  locale: { template_type?: string | null; storage_path?: string | null } | null | undefined,
): boolean {
  return Boolean(
    locale &&
      locale.template_type === 'docx' &&
      typeof locale.storage_path === 'string' &&
      locale.storage_path.length > 0,
  )
}

/** Second isolation check in render-commercial-document (resolver already filters). */
export function isFullBodyTemplateOwnedByTenant(
  template: {
    tenant_id?: string | null
    is_platform_default?: boolean | null
    is_active?: boolean | null
  } | null | undefined,
  tenantId: string,
): boolean {
  if (!template || template.is_active === false) return false
  return (
    template.tenant_id === tenantId ||
    (template.tenant_id == null && template.is_platform_default === true)
  )
}

export function buildCommercialTemplateContext(
  input: BuildCommercialTemplateContextInput,
): Record<string, unknown> {
  const now = input.now ?? new Date()
  const today = now.toISOString().split('T')[0]
  const doc = input.doc
  const seller = asRecord(doc.seller_snapshot)
  const buyer = asRecord(doc.buyer_snapshot)
  const tenantTaxId = str(input.tenant.tax_id) ?? str(seller.tax_id)
  const dateFormat = str(input.dateFormat) ?? DEFAULT_COMMERCIAL_DATE_FORMAT
  const timeFormat = str(input.timeFormat) ?? DEFAULT_COMMERCIAL_TIME_FORMAT
  const locale = str(doc.locale) ?? 'ca'
  const issuedAt = str(doc.issued_at)
  const validUntil = str(doc.valid_until)
  const createdAt = str(doc.created_at)

  return {
    globals: {
      today,
      date: today,
      year: String(now.getFullYear()),
      now: now.toISOString(),
    },
    tenant: {
      name: str(input.tenant.name),
      tax_id: tenantTaxId,
      address: str(input.tenant.address),
      phone: str(input.tenant.phone),
      email: str(input.tenant.email),
      logo_url: str(input.logoUrl) ?? str(input.tenant.logo_url),
    },
    document: {
      doc_type: str(doc.doc_type),
      doc_number: str(doc.doc_number),
      status: str(doc.status),
      locale,
      currency: str(doc.currency) ?? 'EUR',
      issued_at: issuedAt,
      valid_until: validUntil,
      created_at: createdAt,
      issued_at_display: formatCommercialDisplayDateTime(issuedAt, locale, dateFormat, timeFormat),
      valid_until_display: formatCommercialDisplayDate(validUntil, locale, dateFormat),
      created_at_display: formatCommercialDisplayDateTime(createdAt, locale, dateFormat, timeFormat),
      is_amendment: doc.doc_type === 'quote_amendment',
      parent_doc_number: str(input.parentDocNumber),
      show_prices: doc.show_prices !== false,
      terms_text: str(doc.terms_text),
    },
    seller: partyFields(seller),
    buyer: partyFields(buyer),
    service_address: serviceAddress(asRecord(doc.service_address_snapshot)),
    lines: input.lines.map((line) => ({
      name: str(line.name),
      description: str(line.description),
      unit: str(line.unit),
      quantity: num(line.quantity),
      unit_price: num(line.unit_price),
      discount_pct: num(line.discount_pct),
      tax_rate: num(line.tax_rate),
      line_total: num(line.line_total),
      kind: str(line.kind),
    })),
    totals: {
      subtotal: num(doc.subtotal),
      tax_breakdown: taxBreakdown(doc.tax_breakdown, input.lines),
      total: num(doc.total),
    },
    legal: {
      retention_days: COMMERCIAL_LEGAL_RETENTION_DAYS,
      jurisdiction_text: '',
    },
  }
}

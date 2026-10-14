/**
 * Closed commercial template vocabulary (CF-24).
 * Keep in sync with docs/plans/commercial-flow/cf24-closed-vocabulary.md
 * and supabase/functions/_shared/commercial-document-context.ts /
 * commercial-agreement-context.ts.
 */

export type CommercialVocabFamily = 'quote' | 'delivery_note' | 'commercial_agreement'

const PARTY_FIELDS = [
  'display_name',
  'tax_id',
  'email',
  'phone',
  'address_line1',
  'address_line2',
  'city',
  'postal_code',
] as const

const QUOTE_LINE_FIELDS = [
  'name',
  'description',
  'unit',
  'quantity',
  'unit_price',
  'discount_pct',
  'tax_rate',
  'line_total',
  'kind',
] as const

const AGREEMENT_LINE_FIELDS = [
  ...QUOTE_LINE_FIELDS.filter((f) => f !== 'kind'),
  'line_subtotal',
] as const

/** Exact dotted paths allowed in quote / delivery_note templates. */
export const QUOTE_ALLOWED_PATHS: ReadonlySet<string> = new Set([
  'globals.today',
  'globals.date',
  'globals.year',
  'globals.now',
  'tenant.name',
  'tenant.tax_id',
  'tenant.address',
  'tenant.phone',
  'tenant.email',
  'tenant.logo_url',
  'document.doc_type',
  'document.doc_number',
  'document.status',
  'document.locale',
  'document.currency',
  'document.issued_at',
  'document.valid_until',
  'document.created_at',
  'document.issued_at_display',
  'document.valid_until_display',
  'document.created_at_display',
  'document.is_amendment',
  'document.parent_doc_number',
  'document.show_prices',
  'document.terms_text',
  ...PARTY_FIELDS.map((f) => `seller.${f}`),
  ...PARTY_FIELDS.map((f) => `buyer.${f}`),
  'service_address.label',
  'service_address.line1',
  'service_address.line2',
  'service_address.city',
  'service_address.postal_code',
  'service_address.region',
  'service_address.country',
  'lines',
  ...QUOTE_LINE_FIELDS.map((f) => `line.${f}`),
  ...QUOTE_LINE_FIELDS.map((f) => `lines.${f}`),
  // Docxtemplater scopes bare fields inside [[#lines]] / tax_breakdown loops
  ...QUOTE_LINE_FIELDS,
  'tax_rate',
  'tax_amount',
  'tax_base',
  'totals.subtotal',
  'totals.total',
  'totals.tax_breakdown',
  'totals.tax_breakdown.tax_rate',
  'totals.tax_breakdown.tax_amount',
  'totals.tax_breakdown.tax_base',
  'tax.tax_rate',
  'tax.tax_amount',
  'tax.tax_base',
  'legal.retention_days',
  'legal.jurisdiction_text',
])

export const AGREEMENT_ALLOWED_PATHS: ReadonlySet<string> = new Set([
  'agreement.id',
  'agreement.status',
  'agreement.kind',
  'agreement.work_gate',
  'agreement.starts_on',
  'agreement.ends_on',
  'agreement.notice_days',
  'agreement.sla.response_hours',
  'agreement.sla.resolution_hours',
  'agreement.sla.coverage_notes',
  'agreement.billing.cadence',
  'agreement.billing.amount_cents',
  'agreement.billing.currency',
  'agreement.billing.anchor_day',
  'agreement.billing.next_billing_on',
  'source_quote.id',
  'source_quote.doc_number',
  'source_quote.content_hash',
  'source_quote.document_id',
  'document.locale',
  'document.currency',
  'tenant.name',
  'tenant.tax_id',
  'tenant.logo_url',
  'seller.display_name',
  'seller.tax_id',
  'seller.email',
  'seller.phone',
  'seller.address',
  'buyer.display_name',
  'buyer.tax_id',
  'buyer.email',
  'buyer.phone',
  'buyer.address',
  'lines',
  ...AGREEMENT_LINE_FIELDS.map((f) => `line.${f}`),
  ...AGREEMENT_LINE_FIELDS.map((f) => `lines.${f}`),
  ...AGREEMENT_LINE_FIELDS,
  'totals.subtotal',
  'totals.total',
  'totals.tax_breakdown',
])

const PATH_SUGGESTIONS: Record<string, string> = {
  'buyer.name': 'buyer.display_name',
  'buyer.legal_name': 'buyer.display_name',
  'seller.name': 'seller.display_name',
  'seller.legal_name': 'seller.display_name',
  'client.display_name': 'buyer.display_name',
  'client.name': 'buyer.display_name',
  'client.tax_id': 'buyer.tax_id',
  'client.email': 'buyer.email',
  'buyer.address': 'buyer.address_line1',
  'seller.address': 'seller.address_line1',
}

const LIQUID_OUTPUT_RE = /\{\{\s*([a-zA-Z_][\w.]*)\s*(?:\|[^}]*)?\}\}/g
const LIQUID_FOR_RE = /\{%\s*for\s+\w+\s+in\s+([a-zA-Z_][\w.]*)\s*%\}/g
const DOCX_PATH_RE = /\[\[(?!\/|#)([a-zA-Z_][\w.]*)\]\]/g
const DOCX_LOOP_RE = /\[\[#([a-zA-Z_][\w.]*)\]\]/g

export function allowedPathsForFamily(family: CommercialVocabFamily): ReadonlySet<string> {
  return family === 'commercial_agreement' ? AGREEMENT_ALLOWED_PATHS : QUOTE_ALLOWED_PATHS
}

export function suggestCorrectPath(badPath: string): string | null {
  return PATH_SUGGESTIONS[badPath] ?? null
}

/** Extract dotted context paths from Liquid HTML or Docxtemplater plain text. */
export function extractCommercialTemplatePaths(content: string, syntax: 'html' | 'docx'): string[] {
  const found = new Set<string>()
  if (syntax === 'html') {
    for (const re of [LIQUID_OUTPUT_RE, LIQUID_FOR_RE]) {
      re.lastIndex = 0
      let m: RegExpExecArray | null
      while ((m = re.exec(content)) !== null) {
        const path = m[1]?.trim()
        if (path) found.add(path)
      }
    }
  } else {
    for (const re of [DOCX_PATH_RE, DOCX_LOOP_RE]) {
      re.lastIndex = 0
      let m: RegExpExecArray | null
      while ((m = re.exec(content)) !== null) {
        const path = m[1]?.trim()
        if (path) found.add(path)
      }
    }
  }
  return [...found].sort()
}

export type UnknownPathHit = {
  path: string
  suggestion: string | null
}

export function findUnknownCommercialPaths(
  content: string,
  family: CommercialVocabFamily,
  syntax: 'html' | 'docx',
): UnknownPathHit[] {
  const allowed = allowedPathsForFamily(family)
  const paths = extractCommercialTemplatePaths(content, syntax)
  return paths
    .filter((path) => !allowed.has(path))
    .map((path) => ({ path, suggestion: suggestCorrectPath(path) }))
}

export function formatUnknownPathMessage(hits: UnknownPathHit[]): string {
  return hits
    .map((hit) =>
      hit.suggestion ? `${hit.path} → usa ${hit.suggestion}` : hit.path,
    )
    .join(', ')
}

export function commercialVocabFamilyFromCategory(
  category: string | null | undefined,
): CommercialVocabFamily | null {
  if (category === 'quote' || category === 'delivery_note' || category === 'commercial_agreement') {
    return category
  }
  return null
}

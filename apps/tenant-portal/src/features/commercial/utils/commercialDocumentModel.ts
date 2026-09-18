export type CommercialPartySnapshot = {
  display_name?: string | null
  legal_name?: string | null
  name?: string | null
  tax_id?: string | null
  email?: string | null
  phone?: string | null
  address_line1?: string | null
  address_line2?: string | null
  city?: string | null
  postal_code?: string | null
  is_consumer?: boolean | null
  preferred_locale?: string | null
  slug?: string | null
  logo_url?: string | null
}

export type CommercialAddressSnapshot = {
  label?: string | null
  line1?: string | null
  line2?: string | null
  city?: string | null
  postal_code?: string | null
  region?: string | null
  country?: string | null
}

export type CommercialTaxBreakdownRow = {
  tax_rate?: number | string
  tax_amount?: number | string
  tax_base?: number | string
}

export type CommercialDocumentLine = {
  id: string
  document_id: string
  kind: string
  name: string
  description: string | null
  unit: string
  quantity: number
  unit_price: number
  discount_pct: number
  tax_rate: number
  line_subtotal: number
  line_tax: number
  line_total: number
  position: number
}

export type CommercialDocumentDetail = {
  id: string
  tenant_id: string
  doc_type: 'quote' | 'quote_amendment' | 'delivery_note'
  doc_number: string | null
  client_id: string
  project_id: string | null
  status: string
  seller_snapshot: CommercialPartySnapshot
  buyer_snapshot: CommercialPartySnapshot
  service_address_snapshot: CommercialAddressSnapshot
  terms_text: string | null
  locale: string
  currency: string
  subtotal: number
  tax_breakdown: CommercialTaxBreakdownRow[]
  total: number
  show_prices: boolean
  issued_at: string | null
  valid_until: string | null
  parent_document_id: string | null
  created_at: string
  rendered_document_id?: string | null
  pdf_job_id?: string | null
  document_template_id?: string | null
  full_body_template_id?: string | null
  lines: CommercialDocumentLine[]
  events: CommercialDocumentEvent[]
}

export type CommercialDocumentEvent = {
  id: string
  event_type: string
  occurred_at: string
  channel: string | null
}

export function docTypeLabel(docType: string): string {
  switch (docType) {
    case 'quote':
      return 'Pressupost'
    case 'quote_amendment':
      return 'Ampliació'
    case 'delivery_note':
      return 'Albarà'
    default:
      return docType
  }
}

export function partyDisplayName(party: CommercialPartySnapshot | null | undefined): string {
  if (!party) return '—'
  return (
    party.display_name?.trim() ||
    party.legal_name?.trim() ||
    party.name?.trim() ||
    '—'
  )
}

export function formatMoney(value: number | string | null | undefined, currency = 'EUR'): string {
  const n = Number(value ?? 0)
  try {
    return new Intl.NumberFormat('ca-ES', {
      style: 'currency',
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(n)
  } catch {
    return `${n.toFixed(2)} €`
  }
}

export function taxTotalFromBreakdown(rows: CommercialTaxBreakdownRow[] | null | undefined): number {
  if (!Array.isArray(rows)) return 0
  return rows.reduce((sum, row) => sum + Number(row.tax_amount ?? 0), 0)
}

export function formatAddress(addr: CommercialAddressSnapshot | null | undefined): string {
  if (!addr) return ''
  const parts = [
    addr.label,
    addr.line1,
    addr.line2,
    [addr.postal_code, addr.city].filter(Boolean).join(' '),
    addr.region,
    addr.country,
  ].filter((p) => typeof p === 'string' && p.trim().length > 0)
  return parts.join(', ')
}

export function formatCommercialEventDate(iso: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return iso
  return date.toLocaleString('ca-ES', { dateStyle: 'short', timeStyle: 'short' })
}

export const COMMERCIAL_LIFECYCLE_EVENT_TYPES = [
  'issued',
  'sent',
  'accepted',
  'rejected',
  'cancelled',
  'superseded',
  'signed',
] as const

export function commercialFilename(
  doc: Pick<CommercialDocumentDetail, 'doc_number' | 'doc_type'>,
  ext = 'html',
): string {
  const base = (doc.doc_number ?? doc.doc_type).replace(/[^\w.-]+/g, '_')
  return `${base}.${ext}`
}

export function buildCommercialShareText(doc: CommercialDocumentDetail): string {
  const title = docTypeLabel(doc.doc_type)
  const number = doc.doc_number ?? '—'
  const seller = partyDisplayName(doc.seller_snapshot)
  const buyer = partyDisplayName(doc.buyer_snapshot)
  const lines = [
    `${title} ${number}`,
    `${seller} → ${buyer}`,
    `Total: ${formatMoney(doc.total, doc.currency)}`,
  ]
  if (doc.valid_until) {
    lines.push(`Vàlid fins: ${new Date(doc.valid_until).toLocaleDateString('ca-ES')}`)
  }
  if (doc.show_prices !== false) {
    const preview = doc.lines
      .slice(0, 8)
      .map(
        (line) =>
          `· ${line.name}: ${Number(line.quantity)} ${line.unit} × ${formatMoney(line.unit_price, doc.currency)}`,
      )
    lines.push(...preview)
    if (doc.lines.length > 8) lines.push(`· … (+${doc.lines.length - 8})`)
  }
  return lines.join('\n')
}

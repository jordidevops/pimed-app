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
  doc_type: 'quote' | 'quote_amendment' | 'delivery_note' | 'invoice'
  doc_number: string | null
  title?: string | null
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
    formalization_mode?: 'signed_quote' | 'separate_agreement' | null
    draft_wizard_step?: 'lines' | 'template' | 'issue' | null
    invoice_id?: string | null
    invoice_doc_number?: string | null
    external_invoice_ref?: string | null
    supersedes_id?: string | null
  lines: CommercialDocumentLine[]
  events: CommercialDocumentEvent[]
}

export type CommercialDocumentEvent = {
  id: string
  event_type: string
  occurred_at: string
  channel: string | null
  actor_id?: string | null
  payload?: Record<string, unknown> | null
  signature?: Record<string, unknown> | null
}

/** True when the quote was issued (or created) without an order — «Només pressupost». */
export function isQuoteIssuedAsOrphan(
  events: CommercialDocumentEvent[] | null | undefined,
  projectId: string | null | undefined,
): boolean {
  const list = events ?? []
  if (
    list.some(
      (e) =>
        e.event_type === 'issued' &&
        e.payload != null &&
        e.payload.orphan === true,
    )
  ) {
    return true
  }
  if (list.some((e) => e.payload?.project_created_from_quote === true)) {
    return true
  }
  if (list.some((e) => e.event_type === 'project_linked')) {
    return true
  }
  return !projectId
}

export type CommercialLifecycleDisplayEvent = CommercialDocumentEvent & {
  /** UI-only; collapsed accepted / ordre creada rows share underlying event ids. */
  displayKind?: 'accepted' | 'order_created'
  displayKey?: string
}

/**
 * One Acceptat row + optional Ordre creada when ensure_project tagged a duplicate accept.
 */
export function collapseQuoteLifecycleEvents(
  events: CommercialDocumentEvent[],
): CommercialLifecycleDisplayEvent[] {
  const accepted = events.filter((e) => e.event_type === 'accepted')
  const rest = events.filter(
    (e) => e.event_type !== 'accepted' && e.event_type !== 'project_linked',
  )
  const projectLinked = events.filter((e) => e.event_type === 'project_linked')
  const orderFromAccept = accepted.find(
    (e) => e.payload?.project_created_from_quote === true,
  )
  const orderEvent = orderFromAccept ?? projectLinked[0] ?? null

  const preferredAccept =
    accepted.find((e) => e.payload?.project_created_from_quote !== true) ?? accepted[0]

  const out: CommercialLifecycleDisplayEvent[] = rest.map((e) => ({ ...e }))
  if (preferredAccept) {
    out.push({
      ...preferredAccept,
      displayKind: 'accepted',
      displayKey: `${preferredAccept.id}-accepted`,
    })
  }
  if (orderEvent) {
    out.push({
      ...orderEvent,
      displayKind: 'order_created',
      displayKey: `${orderEvent.id}-order`,
    })
  }

  out.sort((a, b) => {
    const ta = new Date(a.occurred_at).getTime()
    const tb = new Date(b.occurred_at).getTime()
    if (ta !== tb) return ta - tb
    if (a.displayKind === 'accepted' && b.displayKind === 'order_created') return -1
    if (a.displayKind === 'order_created' && b.displayKind === 'accepted') return 1
    return (a.displayKey ?? a.id).localeCompare(b.displayKey ?? b.id)
  })
  return out
}

/** True when the latest accept event was an office attestation (no client pad). */
export function isOfficeAcceptedEvent(
  events: CommercialDocumentEvent[] | null | undefined,
): boolean {
  const accepted = [...(events ?? [])]
    .reverse()
    .find((event) => event.event_type === 'accepted')
  if (!accepted) return false
  const sig = accepted.signature
  if (sig && typeof sig === 'object' && !Array.isArray(sig)) {
    if (sig.role === 'office_accept') return true
    if (sig.method === 'office' && sig.role !== 'office_reject') return true
  }
  const payload = accepted.payload
  if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
    const nested = payload.signature
    if (nested && typeof nested === 'object' && !Array.isArray(nested)) {
      const role = (nested as Record<string, unknown>).role
      const method = (nested as Record<string, unknown>).method
      if (role === 'office_accept') return true
      if (method === 'office' && role !== 'office_reject') return true
    }
  }
  return false
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

/** Heading for the document page. Prefer official `doc_number` in the title. */
export function commercialDocumentHeading(
  doc: {
    doc_type: string
    title?: string | null
    doc_number?: string | null
    buyer_snapshot?: CommercialPartySnapshot | null
  },
  typeLabel: string,
): string {
  const number = doc.doc_number?.trim()
  if (number) return `${typeLabel} · ${number}`
  const custom = doc.title?.trim()
  if (custom) return custom
  const client = partyDisplayName(doc.buyer_snapshot)
  if (client && client !== '—') return `${typeLabel} · ${client}`
  return typeLabel
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
  'invoice_cancelled',
  'payment_recorded',
  'project_linked',
  'project_not_needed',
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

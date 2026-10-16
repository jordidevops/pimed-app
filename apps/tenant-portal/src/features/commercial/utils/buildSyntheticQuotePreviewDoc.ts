import type { OutputLine } from '@pimed/price-calculator'
import type {
  CommercialDocumentDetail,
  CommercialDocumentLine,
  CommercialPartySnapshot,
} from './commercialDocumentModel'
import type { FormalizationMode } from './deviationApprovalThreshold'

export type SyntheticPreviewLineInput = {
  kind: string
  name: string
  description?: string | null
  unit: string
  quantity: number
  unit_price: number
  discount_pct?: number
  tax_rate?: number
}

export function outputLinesToSyntheticInputs(lines: OutputLine[]): SyntheticPreviewLineInput[] {
  return lines.map((line) => ({
    kind: line.kind,
    name: line.name,
    description: line.description,
    unit: line.unit,
    quantity: Number(line.quantity),
    unit_price: Number(line.unit_price),
    discount_pct: Number(line.discount_pct),
    tax_rate: Number(line.tax_rate),
  }))
}

export function buildSyntheticQuotePreviewDoc(input: {
  tenantId: string
  clientId: string
  title?: string
  buyer?: CommercialPartySnapshot
  formalizationMode?: FormalizationMode | null
  templateId?: string | null
  lines: SyntheticPreviewLineInput[]
}): CommercialDocumentDetail {
  const lines: CommercialDocumentLine[] = input.lines.map((row, index) => {
    const quantity = Number(row.quantity ?? 1)
    const unitPrice = Number(row.unit_price ?? 0)
    const discount = Number(row.discount_pct ?? 0)
    const tax = Number(row.tax_rate ?? 21)
    const subtotal = quantity * unitPrice * (1 - discount / 100)
    const lineTax = subtotal * (tax / 100)
    return {
      id: `preview-line-${index}`,
      document_id: 'preview',
      kind: row.kind === 'product' ? 'product' : 'service',
      name: row.name,
      description: row.description ?? null,
      unit: row.unit || 'u',
      quantity,
      unit_price: unitPrice,
      discount_pct: discount,
      tax_rate: tax,
      line_subtotal: subtotal,
      line_tax: lineTax,
      line_total: subtotal + lineTax,
      position: index,
    }
  })
  const subtotal = lines.reduce((sum, line) => sum + line.line_subtotal, 0)
  const total = lines.reduce((sum, line) => sum + line.line_total, 0)
  const now = new Date().toISOString()
  return {
    id: 'preview',
    tenant_id: input.tenantId,
    doc_type: 'quote',
    doc_number: null,
    title: input.title ?? null,
    client_id: input.clientId,
    project_id: null,
    status: 'draft',
    seller_snapshot: {},
    buyer_snapshot: input.buyer ?? {},
    service_address_snapshot: {},
    terms_text: null,
    locale: 'ca',
    currency: 'EUR',
    subtotal,
    tax_breakdown: [],
    total,
    show_prices: true,
    issued_at: null,
    valid_until: null,
    parent_document_id: null,
    created_at: now,
    full_body_template_id: input.templateId || null,
    formalization_mode: input.formalizationMode ?? null,
    lines,
    events: [],
  }
}

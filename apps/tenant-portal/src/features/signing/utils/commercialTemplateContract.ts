import type { CommercialFullBodyCategory } from './templateCategories'

export type CommercialTemplateSyntax = 'html' | 'docx'

type TokenDef = { id: string; html: string; docx: string }

export const QUOTE_REQUIRED_TOKENS: TokenDef[] = [
  { id: 'lines_loop', html: '{% for line in lines %}', docx: '[[#lines]]' },
  { id: 'totals.total', html: 'totals.total', docx: 'totals.total' },
  { id: 'document.doc_number', html: 'document.doc_number', docx: 'document.doc_number' },
  { id: 'document.valid_until', html: 'document.valid_until', docx: 'document.valid_until' },
  { id: 'tax_breakdown', html: 'totals.tax_breakdown', docx: 'totals.tax_breakdown' },
  { id: 'client_accept', html: 'role="client_accept"', docx: 'role=client_accept' },
  { id: 'client_reject', html: 'role="client_reject"', docx: 'role=client_reject' },
]

export const DELIVERY_NOTE_REQUIRED_TOKENS: TokenDef[] = [
  { id: 'lines_loop', html: '{% for line in lines %}', docx: '[[#lines]]' },
  { id: 'document.doc_number', html: 'document.doc_number', docx: 'document.doc_number' },
  { id: 'client_delivery', html: 'role="client_delivery"', docx: 'role=client_delivery' },
]

export function commercialRequiredTokens(
  category: CommercialFullBodyCategory,
  syntax: CommercialTemplateSyntax = 'html',
) {
  const tokens = category === 'delivery_note' ? DELIVERY_NOTE_REQUIRED_TOKENS : QUOTE_REQUIRED_TOKENS
  return tokens.map((token) => ({ id: token.id, example: token[syntax] }))
}

export const COMMERCIAL_CONTEXT_FIELDS = [
  'tenant.name / tenant.email / tenant.logo_url',
  'document.doc_number / document.issued_at / document.valid_until / document.show_prices',
  'seller.display_name / buyer.display_name',
  'service_address.line1 / service_address.city',
  'lines[].name / quantity / unit_price / line_total',
  'totals.subtotal / totals.tax_breakdown[].tax_rate / tax_amount / totals.total',
] as const

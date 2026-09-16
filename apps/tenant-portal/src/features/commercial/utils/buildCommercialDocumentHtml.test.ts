import { describe, expect, it } from 'vitest'
import { buildCommercialDocumentHtml } from './buildCommercialDocumentHtml'
import type { CommercialDocumentDetail, CommercialDocumentLine } from './commercialDocumentModel'

function line(partial: Partial<CommercialDocumentLine> & { name: string }): CommercialDocumentLine {
  return {
    id: partial.id ?? 'line-1',
    document_id: 'doc-1',
    kind: 'service',
    name: partial.name,
    description: partial.description ?? null,
    unit: partial.unit ?? 'u',
    quantity: partial.quantity ?? 2,
    unit_price: partial.unit_price ?? 50,
    discount_pct: partial.discount_pct ?? 0,
    tax_rate: 21,
    line_subtotal: 100,
    line_tax: 21,
    line_total: partial.line_total ?? 100,
    position: 0,
  }
}

function doc(
  overrides: Partial<CommercialDocumentDetail> = {},
): CommercialDocumentDetail {
  return {
    id: 'doc-1',
    tenant_id: 'tenant-1',
    doc_type: 'quote',
    doc_number: 'PRE-2026-0001',
    client_id: 'client-1',
    project_id: 'project-1',
    status: 'issued',
    seller_snapshot: {
      display_name: 'Taller Nord',
      tax_id: 'B12345678',
      logo_url: 'https://cdn.example/logo.png',
    },
    buyer_snapshot: {
      display_name: 'Maria Client',
      tax_id: '12345678Z',
      preferred_locale: 'ca',
    },
    service_address_snapshot: {
      line1: 'Carrer Major 1',
      city: 'Vic',
      postal_code: '08500',
    },
    terms_text: 'Pagament 15 dies',
    locale: 'ca',
    currency: 'EUR',
    subtotal: 100,
    tax_breakdown: [{ tax_rate: 21, tax_amount: 21 }],
    total: 121,
    show_prices: true,
    issued_at: '2026-09-16T10:00:00.000Z',
    valid_until: '2026-10-16',
    parent_document_id: null,
    created_at: '2026-09-16T10:00:00.000Z',
    lines: [line({ name: 'Visita estàndard', description: 'Desplaçament inclòs' })],
    events: [],
    ...overrides,
  }
}

describe('buildCommercialDocumentHtml', () => {
  it('embeds the seller logo and Catalan labels from the snapshot locale', () => {
    const html = buildCommercialDocumentHtml(doc())
    expect(html).toContain('lang="ca"')
    expect(html).toContain('src="https://cdn.example/logo.png"')
    expect(html).toContain('Emissor')
    expect(html).toContain('Client')
    expect(html).toContain('Concepte')
    expect(html).toContain('Pressupost PRE-2026-0001')
    expect(html).toContain('Visita estàndard')
    expect(html).toContain('Desplaçament inclòs')
    expect(html).toContain('Taller Nord')
    expect(html).toContain('Maria Client')
    expect(html).toContain('Estat: Pendent de resposta')
    expect(html).not.toContain('Estat: issued')
  })

  it('uses Spanish labels when the document locale is es', () => {
    const html = buildCommercialDocumentHtml(doc({ locale: 'es' }))
    expect(html).toContain('lang="es"')
    expect(html).toContain('Presupuesto')
    expect(html).toContain('Emisor')
    expect(html).toContain('Cliente')
    expect(html).toContain('Concepto')
    expect(html).not.toContain('>Emissor<')
  })

  it('translates issued delivery notes as Emès', () => {
    const html = buildCommercialDocumentHtml(
      doc({ doc_type: 'delivery_note', doc_number: 'ALB-1', status: 'issued' }),
    )
    expect(html).toContain('Estat: Emès')
    expect(html).not.toContain('Estat: issued')
  })

  it('renders priced lines and totals when show_prices is true', () => {
    const html = buildCommercialDocumentHtml(doc())
    expect(html).toContain('Preu')
    expect(html).toContain('Import')
    expect(html).toContain('Base')
    expect(html).toContain('IVA')
    expect(html).toContain('Total')
  })

  it('hides prices when show_prices is false', () => {
    const html = buildCommercialDocumentHtml(doc({ show_prices: false }))
    expect(html).toContain('Visita estàndard')
    expect(html).toContain('Quantitat')
    expect(html).not.toContain('>Preu<')
    expect(html).not.toContain('<span>Base</span>')
    expect(html).not.toContain('<span>Total</span>')
  })
})

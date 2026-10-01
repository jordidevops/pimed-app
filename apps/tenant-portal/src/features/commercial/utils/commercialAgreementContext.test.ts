import { describe, expect, it } from 'vitest'
import { buildAgreementTemplateContext } from './commercialAgreementContext'

describe('agreement template context', () => {
  it('keeps the accepted quote hash and uses the client signature role context', () => {
    const context = buildAgreementTemplateContext({
      agreementId: 'agr',
      agreementStatus: 'pending_start',
      workGate: 'none',
      quoteId: 'quote',
      quoteNumber: 'P-1',
      quoteContentHash: 'abc123',
      quoteDocumentId: null,
      locale: 'ca',
      currency: 'EUR',
      subtotal: 10,
      total: 12.1,
      lines: [{ name: 'Visita', line_total: 12.1 }],
      tenantName: 'Volt',
      sellerName: 'Volt',
      buyerName: 'Client',
    })
    const quote = context.source_quote as { doc_number: string; content_hash: string }
    expect(quote.doc_number).toBe('P-1')
    expect(quote.content_hash).toBe('abc123')
    expect(context.lines).toEqual([{ name: 'Visita', line_total: 12.1 }])
  })

  it('exposes SLA and validity fields for Liquid templates', () => {
    const context = buildAgreementTemplateContext({
      agreementId: 'agr',
      agreementStatus: 'active',
      agreementKind: 'recurring',
      workGate: 'none',
      startsOn: '2026-01-01',
      endsOn: '2026-12-31',
      noticeDays: 30,
      sla: { responseHours: 4, resolutionHours: 24, coverageNotes: '8-18' },
      quoteId: null,
      quoteNumber: null,
      quoteContentHash: null,
      quoteDocumentId: null,
      locale: 'ca',
      currency: 'EUR',
      subtotal: 0,
      total: 0,
      lines: [],
      tenantName: 'Volt',
      sellerName: 'Volt',
      buyerName: 'Client',
    })
    const agreement = context.agreement as {
      kind: string
      starts_on: string
      sla: { response_hours: number; coverage_notes: string }
    }
    expect(agreement.kind).toBe('recurring')
    expect(agreement.starts_on).toBe('2026-01-01')
    expect(agreement.sla.response_hours).toBe(4)
    expect(agreement.sla.coverage_notes).toBe('8-18')
    const quote = context.source_quote as { doc_number: string; content_hash: string }
    expect(quote.doc_number).toBe('—')
    expect(quote.content_hash).toBe('sense-annex')
  })

  it('exposes billing cadence for Liquid templates', () => {
    const context = buildAgreementTemplateContext({
      agreementId: 'agr',
      agreementStatus: 'active',
      agreementKind: 'recurring',
      workGate: 'none',
      billing: { cadence: 'monthly', amountCents: 12100, currency: 'EUR', anchorDay: 1 },
      quoteId: null,
      quoteNumber: null,
      quoteContentHash: null,
      quoteDocumentId: null,
      locale: 'ca',
      currency: 'EUR',
      subtotal: 0,
      total: 0,
      lines: [],
      tenantName: 'Volt',
      sellerName: 'Volt',
      buyerName: 'Client',
    })
    const agreement = context.agreement as {
      billing: { cadence: string; amount_cents: number }
    }
    expect(agreement.billing.cadence).toBe('monthly')
    expect(agreement.billing.amount_cents).toBe(12100)
  })
})


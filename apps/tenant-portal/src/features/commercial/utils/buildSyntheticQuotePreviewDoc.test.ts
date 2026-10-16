import { describe, expect, it } from 'vitest'
import { buildSyntheticQuotePreviewDoc } from './buildSyntheticQuotePreviewDoc'

describe('buildSyntheticQuotePreviewDoc', () => {
  it('computes line and document totals', () => {
    const doc = buildSyntheticQuotePreviewDoc({
      tenantId: 't1',
      clientId: 'c1',
      title: 'Prova',
      formalizationMode: 'signed_quote',
      templateId: 'tpl',
      lines: [
        {
          kind: 'service',
          name: 'Hores',
          unit: 'h',
          quantity: 2,
          unit_price: 40,
          discount_pct: 0,
          tax_rate: 21,
        },
      ],
    })
    expect(doc.lines).toHaveLength(1)
    expect(doc.lines[0].line_subtotal).toBe(80)
    expect(doc.lines[0].line_tax).toBeCloseTo(16.8)
    expect(doc.total).toBeCloseTo(96.8)
    expect(doc.full_body_template_id).toBe('tpl')
  })
})

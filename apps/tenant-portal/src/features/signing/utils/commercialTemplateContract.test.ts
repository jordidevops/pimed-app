import { describe, expect, it } from 'vitest'
import { commercialRequiredTokens } from './commercialTemplateContract'

describe('commercialRequiredTokens', () => {
  it('returns HTML §2.1 examples by default', () => {
    const tokens = commercialRequiredTokens('quote')
    expect(tokens.map((t) => t.id)).toEqual([
      'lines_loop',
      'totals.total',
      'document.doc_number',
      'document.valid_until',
      'tax_breakdown',
      'client_accept',
      'client_reject',
    ])
    expect(tokens[0]?.example).toBe('{% for line in lines %}')
    expect(tokens.find((t) => t.id === 'client_accept')?.example).toBe('role="client_accept"')
  })

  it('returns DOCX §2.1 examples when syntax is docx', () => {
    const tokens = commercialRequiredTokens('quote', 'docx')
    expect(tokens[0]?.example).toBe('[[#lines]]')
    expect(tokens.find((t) => t.id === 'client_accept')?.example).toBe('role=client_accept')
    expect(commercialRequiredTokens('delivery_note', 'docx').map((t) => t.example)).toEqual([
      '[[#lines]]',
      'document.doc_number',
      'role=client_delivery',
    ])
  })
})

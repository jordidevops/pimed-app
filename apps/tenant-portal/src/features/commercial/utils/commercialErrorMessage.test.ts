import { describe, expect, it } from 'vitest'
import { commercialErrorMessage } from './commercialErrorMessage'

describe('commercialErrorMessage', () => {
  it('maps known PostgREST business codes', () => {
    expect(
      commercialErrorMessage({ code: 'P0001', message: 'external_invoice_number_taken' }),
    ).toContain('número de factura')
    expect(
      commercialErrorMessage({ message: 'delivery_note_invoiced' }),
    ).toContain('albarà')
    expect(
      commercialErrorMessage({ message: 'invoice_delivery_notes_empty_lines' }),
    ).toMatch(/línies/i)
    expect(
      commercialErrorMessage({ message: 'delivery_already_invoiced' }),
    ).toMatch(/factura/i)
  })

  it('explains PGRST202 schema-cache misses', () => {
    expect(
      commercialErrorMessage({
        code: 'PGRST202',
        message: 'Could not find the function api.issue_invoice_from_delivery_notes without parameters',
        details: 'Searched for the function api.issue_invoice_from_delivery_notes without parameters',
      }),
    ).toMatch(/schema cache|migració/i)
  })

  it('reads plain Supabase objects without Error instances', () => {
    expect(
      commercialErrorMessage({
        message: 'payment_exceeds_remaining',
        details: 'remaining=100',
      }),
    ).toContain('pendent')
  })

  it('supports Error and string fallbacks', () => {
    expect(commercialErrorMessage(new Error('boom'))).toBe('boom')
    expect(commercialErrorMessage('raw')).toBe('raw')
    expect(commercialErrorMessage(null)).toMatch(/operació comercial/)
  })
})

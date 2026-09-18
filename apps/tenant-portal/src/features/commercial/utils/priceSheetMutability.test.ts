import { describe, expect, it } from 'vitest'
import {
  canShowQuoteWaiverCta,
  resolvePriceSheetMutability,
  type PriceSheetDocument,
} from './priceSheetMutability'

function doc(
  partial: Partial<PriceSheetDocument> & Pick<PriceSheetDocument, 'id' | 'doc_type' | 'status'>,
): PriceSheetDocument {
  return {
    valid_until: null,
    ...partial,
  }
}

describe('resolvePriceSheetMutability', () => {
  it('locks when a quote is issued and not expired', () => {
    const result = resolvePriceSheetMutability({
      documents: [
        doc({
          id: 'q1',
          doc_type: 'quote',
          status: 'issued',
          valid_until: new Date(Date.now() + 86_400_000).toISOString(),
        }),
      ],
      canEditPricing: true,
      hasWaiver: false,
    })
    expect(result.structureLocked).toBe(true)
    expect(result.lockReason).toBe('quote_in_progress')
    expect(result.blockingDocument?.id).toBe('q1')
    expect(result.showAcceptedBanner).toBe(false)
  })

  it('locks when an amendment is issued even if quote is accepted', () => {
    const result = resolvePriceSheetMutability({
      documents: [
        doc({ id: 'q1', doc_type: 'quote', status: 'accepted' }),
        doc({ id: 'a1', doc_type: 'quote_amendment', status: 'issued' }),
      ],
      canEditPricing: true,
      hasWaiver: false,
    })
    expect(result.structureLocked).toBe(true)
    expect(result.blockingDocument?.id).toBe('a1')
    expect(result.showAcceptedBanner).toBe(false)
  })

  it('does not lock expired issued quotes', () => {
    const result = resolvePriceSheetMutability({
      documents: [
        doc({
          id: 'q1',
          doc_type: 'quote',
          status: 'issued',
          valid_until: new Date(Date.now() - 86_400_000).toISOString(),
        }),
      ],
      canEditPricing: true,
      hasWaiver: false,
    })
    expect(result.structureLocked).toBe(false)
    expect(result.lockReason).toBeNull()
  })

  it('shows accepted banner when accepted and not locked', () => {
    const result = resolvePriceSheetMutability({
      documents: [doc({ id: 'q1', doc_type: 'quote', status: 'accepted' })],
      canEditPricing: true,
      hasWaiver: false,
    })
    expect(result.structureLocked).toBe(false)
    expect(result.showAcceptedBanner).toBe(true)
    expect(result.canMutateStructure).toBe(true)
  })

  it('keeps structure mutable without pricing permission', () => {
    const result = resolvePriceSheetMutability({
      documents: [],
      canEditPricing: false,
      hasWaiver: false,
    })
    expect(result.canMutateStructure).toBe(true)
    expect(result.canEditPricing).toBe(false)
  })
})

describe('canShowQuoteWaiverCta', () => {
  it('hides when issued quote is active', () => {
    expect(
      canShowQuoteWaiverCta([
        doc({ id: 'q1', doc_type: 'quote', status: 'issued' }),
      ]),
    ).toBe(false)
  })

  it('hides when quote is accepted', () => {
    expect(
      canShowQuoteWaiverCta([
        doc({ id: 'q1', doc_type: 'quote', status: 'accepted' }),
      ]),
    ).toBe(false)
  })

  it('shows when latest quote is rejected or cancelled', () => {
    expect(
      canShowQuoteWaiverCta([
        doc({ id: 'q1', doc_type: 'quote', status: 'rejected' }),
      ]),
    ).toBe(true)
    expect(
      canShowQuoteWaiverCta([
        doc({ id: 'q1', doc_type: 'quote', status: 'cancelled' }),
      ]),
    ).toBe(true)
  })

  it('shows when there are no quote-like documents', () => {
    expect(canShowQuoteWaiverCta([])).toBe(true)
  })
})

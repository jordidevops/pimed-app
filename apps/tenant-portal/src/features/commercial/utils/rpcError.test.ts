import { describe, expect, it } from 'vitest'
import {
  classifyPriceSheetRpcError,
  isCommercialPricingPermissionDenied,
  parseCommercialTemplateLegalGaps,
  priceSheetRpcErrorCopy,
  rpcErrorMessage,
} from './rpcError'

describe('rpcErrorMessage', () => {
  it('reads PostgREST-shaped objects that are not Error instances', () => {
    expect(
      rpcErrorMessage({
        code: 'P0001',
        message: 'permission_denied:commercial.pricing.edit',
      }),
    ).toBe('permission_denied:commercial.pricing.edit')
  })

  it('reads Error.message', () => {
    expect(rpcErrorMessage(new Error('pricing_template_not_found'))).toBe(
      'pricing_template_not_found',
    )
  })
})

describe('isCommercialPricingPermissionDenied', () => {
  it('detects the commercial pricing guard from apply_pricing_template', () => {
    expect(
      isCommercialPricingPermissionDenied({
        code: 'P0001',
        message: 'permission_denied:commercial.pricing.edit',
      }),
    ).toBe(true)
    expect(isCommercialPricingPermissionDenied(new Error('project_not_found'))).toBe(false)
  })
})

describe('classifyPriceSheetRpcError', () => {
  it('maps known price-sheet guardrails', () => {
    expect(
      classifyPriceSheetRpcError({
        message: 'permission_denied:commercial.pricing.edit',
      }),
    ).toBe('pricing_permission')
    expect(
      classifyPriceSheetRpcError(new Error('price_sheet_locked:quote_in_progress')),
    ).toBe('quote_in_progress')
    expect(
      classifyPriceSheetRpcError(new Error('commercial_document_lines_immutable')),
    ).toBe('lines_immutable')
    expect(classifyPriceSheetRpcError(new Error('waiver_blocked:quote_active'))).toBe(
      'waiver_blocked',
    )
    expect(classifyPriceSheetRpcError(new Error('other'))).toBe('unknown')
  })
})

describe('priceSheetRpcErrorCopy', () => {
  it('uses the overlay title for a locked price sheet', () => {
    const copy = priceSheetRpcErrorCopy(
      new Error('price_sheet_locked:quote_in_progress'),
      'Imports',
    )
    expect(copy.titleFallback).toBe('Imports bloquejat')
    expect(copy.preferFallbackTitle).toBe(true)
  })
})

describe('parseCommercialTemplateLegalGaps', () => {
  it('extracts missing token ids from the RPC exception', () => {
    expect(
      parseCommercialTemplateLegalGaps(
        new Error('commercial_template_legal_gaps: lines_loop, totals.total, client_accept'),
      ),
    ).toEqual(['lines_loop', 'totals.total', 'client_accept'])
  })

  it('returns null when the error is unrelated', () => {
    expect(parseCommercialTemplateLegalGaps(new Error('permission_denied:settings.manage'))).toBeNull()
  })
})

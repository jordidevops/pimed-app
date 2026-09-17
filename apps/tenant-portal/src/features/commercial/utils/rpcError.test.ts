import { describe, expect, it } from 'vitest'
import {
  isCommercialPricingPermissionDenied,
  parseCommercialTemplateLegalGaps,
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

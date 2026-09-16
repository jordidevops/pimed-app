import { describe, expect, it } from 'vitest'
import {
  commercialDocumentDivergesFromLiveTotal,
  liveProjectLinesTotalCents,
} from './quotePriceDrift'

describe('quotePriceDrift', () => {
  it('sums live line totals in cents', () => {
    expect(
      liveProjectLinesTotalCents([
        { total_with_tax: 100 },
        { total_with_tax: 37.34 },
      ]),
    ).toBe(13734)
  })

  it('does not flag equal totals', () => {
    expect(commercialDocumentDivergesFromLiveTotal(137.34, 13734)).toBe(false)
  })

  it('flags a cent difference', () => {
    expect(commercialDocumentDivergesFromLiveTotal(137.34, 13735)).toBe(true)
  })
})

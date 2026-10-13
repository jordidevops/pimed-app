import { describe, expect, it } from 'vitest'
import { buyerDeliveryDiscrepancies } from './buyerDeliveryDiscrepancy'

describe('buyerDeliveryDiscrepancies', () => {
  it('returns empty when contact matches snapshot', () => {
    expect(
      buyerDeliveryDiscrepancies(
        { display_name: 'A', email: 'a@b.com', phone: '600' },
        { display_name: 'A', email: 'a@b.com', phone: '600' },
      ),
    ).toEqual([])
  })

  it('flags phone/email/name when contact differs', () => {
    const rows = buyerDeliveryDiscrepancies(
      { display_name: 'Old', email: 'old@x.com', phone: '600111222' },
      { display_name: 'New', email: 'new@x.com', phone: '600999888' },
    )
    expect(rows.map((r) => r.field)).toEqual(['phone', 'email', 'display_name'])
    expect(rows.find((r) => r.field === 'phone')?.contact).toBe('600999888')
  })

  it('uses phone_alt when primary phone is empty', () => {
    const rows = buyerDeliveryDiscrepancies(
      { phone: '600111222' },
      { phone: null, phone_alt: '600333444' },
    )
    expect(rows).toEqual([
      { field: 'phone', snapshot: '600111222', contact: '600333444' },
    ])
  })
})

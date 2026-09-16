import { describe, expect, it } from 'vitest'
import type {
  CommercialDocument,
  CommercialPayment,
} from '../api/commercialFlowService'
import {
  accountedPaidCents,
  canCollectDocument,
  remainingCentsForDocument,
} from './paymentAllocation'

function document(
  id: string,
  docType: CommercialDocument['doc_type'],
  status: string,
  total = 100,
  createdAt = '2026-09-14T09:00:00Z',
): CommercialDocument {
  return {
    id,
    tenant_id: 'tenant',
    doc_type: docType,
    doc_number: id,
    client_id: 'client',
    project_id: 'project',
    status,
    subtotal: total,
    total,
    show_prices: true,
    issued_at: createdAt,
    valid_until: null,
    parent_document_id: null,
    supersedes_id: null,
    created_at: createdAt,
  }
}

function payment(documentId: string, amountCents: number): CommercialPayment {
  return {
    id: `p-${documentId}-${amountCents}`,
    tenant_id: 'tenant',
    document_id: documentId,
    amount_cents: amountCents,
    method: 'cash',
    reference: null,
    collected_by: 'user',
    occurred_at: '2026-09-14T09:30:00Z',
    client_op_id: `op-${documentId}-${amountCents}`,
    created_at: '2026-09-14T09:30:00Z',
  }
}

describe('remainingCentsForDocument', () => {
  it('returns own remaining on a collectable delivery', () => {
    const delivery = document('D-1', 'delivery_note', 'issued')
    expect(
      remainingCentsForDocument(delivery, [delivery], [payment('D-1', 4000)]),
    ).toBe(6000)
  })

  it('subtracts accepted quote advances from delivery remaining', () => {
    const quote = document('Q-1', 'quote', 'accepted')
    const delivery = document(
      'D-1',
      'delivery_note',
      'issued',
      100,
      '2026-09-14T09:10:00Z',
    )
    expect(
      remainingCentsForDocument(
        delivery,
        [quote, delivery],
        [payment('Q-1', 2500), payment('D-1', 1500)],
      ),
    ).toBe(6000)
  })

  it('caps quote remaining at the latest delivery remaining', () => {
    const quote = document('Q-1', 'quote', 'accepted', 100)
    const delivery = document(
      'D-1',
      'delivery_note',
      'issued',
      80,
      '2026-09-14T09:10:00Z',
    )
    expect(
      remainingCentsForDocument(quote, [quote, delivery], [payment('Q-1', 1000)]),
    ).toBe(7000)
  })

  it('allows a quote advance before there is a delivery', () => {
    const quote = document('Q-1', 'quote', 'accepted')
    expect(remainingCentsForDocument(quote, [quote], [])).toBe(10000)
    expect(canCollectDocument(quote, [quote], [])).toBe(true)
  })

  it('does not collect an issued quote', () => {
    const quote = document('Q-1', 'quote', 'issued')
    expect(remainingCentsForDocument(quote, [quote], [])).toBe(0)
    expect(canCollectDocument(quote, [quote], [])).toBe(false)
    expect(accountedPaidCents(quote, [quote], [])).toBe(0)
  })

  it('does not treat a non-collectable issued quote as fully paid', () => {
    const quote = document('Q-1', 'quote', 'issued', 137.34)
    expect(accountedPaidCents(quote, [quote], [])).toBe(0)
  })

  it('stops collect when remaining is zero', () => {
    const delivery = document('D-1', 'delivery_note', 'issued')
    expect(
      canCollectDocument(delivery, [delivery], [payment('D-1', 10000)]),
    ).toBe(false)
  })
})

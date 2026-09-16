import { describe, expect, it } from 'vitest'
import type {
  CommercialDocument,
  CommercialPayment,
} from '../../commercial/api/commercialFlowService'
import {
  deriveOrderWorkflow,
  resolveOrderTab,
  tabToSearchParam,
} from './deriveOrderWorkflow'

const NOW = Date.parse('2026-09-14T10:00:00Z')

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
    valid_until: '2026-10-14T09:00:00Z',
    parent_document_id: null,
    supersedes_id: null,
    created_at: createdAt,
  }
}

function payment(documentId: string, amountCents: number): CommercialPayment {
  return {
    id: `payment-${documentId}`,
    tenant_id: 'tenant',
    document_id: documentId,
    amount_cents: amountCents,
    method: 'cash',
    reference: null,
    collected_by: 'user',
    occurred_at: '2026-09-14T09:30:00Z',
    client_op_id: 'payment-op',
    created_at: '2026-09-14T09:30:00Z',
  }
}

function workflow(
  overrides: Partial<Parameters<typeof deriveOrderWorkflow>[0]> = {},
) {
  return deriveOrderWorkflow({
    status: 'draft',
    visitClosed: false,
    reportPublished: false,
    documents: [document('Q-1', 'quote', 'accepted')],
    payments: [],
    hasWaiver: false,
    totalWorkSeconds: 0,
    hasOpenWorkLog: false,
    receiptHandled: true,
    nowMs: NOW,
    ...overrides,
  })
}

describe('deriveOrderWorkflow', () => {
  it('starts authorized draft work with no recorded time', () => {
    const result = workflow()

    expect(result.operationalState).toBe('not_started')
    expect(result.suggestedTab).toBe('do')
    expect(result.primaryAction).toBe('start_work')
  })

  it('resumes a draft order with previous closed work logs', () => {
    const result = workflow({
      documents: [],
      totalWorkSeconds: 6 * 3600 + 17 * 60,
    })

    expect(result.operationalState).toBe('paused')
    expect(result.suggestedTab).toBe('do')
    expect(result.primaryAction).toBe('resume_work')
    expect(result.anomalies).toContain('draft_with_recorded_work')
    expect(result.anomalies).toContain('advanced_without_authorization')
  })

  it('asks for a new quote after the latest quote is rejected', () => {
    const result = workflow({
      documents: [document('Q-REJECTED', 'quote', 'rejected')],
    })

    expect(result.authorizationState).toBe('rejected')
    expect(result.suggestedTab).toBe('prepare')
    expect(result.primaryAction).toBe('create_quote')
    expect(result.reissueFromQuoteId).toBe('Q-REJECTED')
    expect(result.activeQuoteId).toBeNull()
  })

  it('keeps a completed and paid order in Deliver despite inconsistent authorization', () => {
    const rejected = document(
      'Q-2',
      'quote',
      'rejected',
      121.61,
      '2026-09-14T09:10:00Z',
    )
    const delivery = document(
      'D-1',
      'delivery_note',
      'accepted',
      121.61,
      '2026-09-14T09:20:00Z',
    )
    const result = workflow({
      status: 'completed',
      visitClosed: true,
      reportPublished: true,
      documents: [rejected, delivery],
      payments: [payment(delivery.id, 12_161)],
      totalWorkSeconds: 7200,
    })

    expect(result.authorizationState).toBe('inconsistent')
    expect(result.deliveryState).toBe('paid')
    expect(result.suggestedTab).toBe('deliver')
    expect(result.primaryAction).toBe('done')
    expect(result.deliverDone).toBe(true)
    expect(result.anomalies).toContain('advanced_without_authorization')
  })

  it('shows only a live issued quote as the pending quote', () => {
    const expired = document('Q-OLD', 'quote', 'issued')
    expired.valid_until = '2026-09-13T09:00:00Z'

    const result = workflow({ documents: [expired] })

    expect(result.authorizationState).toBe('expired')
    expect(result.activeQuoteId).toBeNull()
    expect(result.primaryAction).toBe('create_quote')
  })

  it('does not require publishing a work report before the delivery note', () => {
    const result = workflow({
      status: 'completed',
      visitClosed: true,
      reportPublished: false,
      totalWorkSeconds: 3600,
    })

    expect(result.reportState).toBe('not_published')
    expect(result.deliveryState).toBe('delivery_pending')
    expect(result.suggestedTab).toBe('deliver')
    expect(result.primaryAction).toBe('show_delivery')
  })

  it('keeps a locally closed visit distinct from server close', () => {
    const result = workflow({ localCloseState: 'local_pending' })

    expect(result.operationalState).toBe('closed')
    expect(result.visitClosed).toBe(false)
    expect(result.visitClosedUi).toBe(true)
    expect(result.deliveryState).toBe('not_started')
    expect(result.primaryAction).toBe('sync_pending')
  })

  it('surfaces a quarantined close-out as action required', () => {
    const result = workflow({ localCloseState: 'action_required' })

    expect(result.visitClosedUi).toBe(true)
    expect(result.primaryAction).toBe('review_sync_error')
  })

  it('treats a locally synced close as delivered work, not a pending CTA', () => {
    const result = workflow({
      localCloseState: 'synced',
      totalWorkSeconds: 3600,
    })

    expect(result.operationalState).toBe('closed')
    expect(result.visitClosed).toBe(false)
    expect(result.visitClosedUi).toBe(true)
    expect(result.primaryAction).toBe('show_delivery')
  })

  it('collects remaining after a partial delivery payment', () => {
    const delivery = document('D-1', 'delivery_note', 'issued', 100)
    const result = workflow({
      visitClosed: true,
      documents: [document('Q-1', 'quote', 'accepted'), delivery],
      payments: [payment(delivery.id, 4000)],
    })

    expect(result.primaryAction).toBe('collect')
    expect(result.remainingCents).toBe(6000)
    expect(result.paymentPending).toBe(true)
    expect(result.deliveryState).toBe('payment_pending')
  })

  it('treats quote advances as reducing delivery remaining', () => {
    const quote = document('Q-1', 'quote', 'accepted', 100)
    const delivery = document(
      'D-1',
      'delivery_note',
      'issued',
      100,
      '2026-09-14T09:10:00Z',
    )
    const result = workflow({
      visitClosed: true,
      documents: [quote, delivery],
      payments: [payment(quote.id, 10000)],
    })

    expect(result.remainingCents).toBe(0)
    expect(result.paymentPending).toBe(false)
    expect(result.deliveryState).toBe('paid')
    expect(result.primaryAction).toBe('done')
  })

  it('keeps the collect CTA when a quote advance is only partial', () => {
    const quote = document('Q-1', 'quote', 'accepted', 100)
    const delivery = document(
      'D-1',
      'delivery_note',
      'issued',
      100,
      '2026-09-14T09:10:00Z',
    )
    const result = workflow({
      visitClosed: true,
      documents: [quote, delivery],
      payments: [payment(quote.id, 2500)],
    })

    expect(result.remainingCents).toBe(7500)
    expect(result.primaryAction).toBe('collect')
  })
})

describe('order phase URL contract', () => {
  it.each([
    ['budget', 'prepare'],
    ['work', 'do'],
    ['punch', 'do'],
    ['bulletin', 'deliver'],
    ['activity', 'activity'],
  ] as const)('normalizes legacy %s to %s', (legacy, canonical) => {
    expect(resolveOrderTab(legacy, 'prepare')).toBe(canonical)
  })

  it('persists the manual Do selection canonically', () => {
    expect(tabToSearchParam('do')).toBe('do')
    expect(resolveOrderTab('do', 'deliver')).toBe('do')
  })
})

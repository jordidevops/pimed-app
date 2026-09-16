import type { CommercialDocument, CommercialPayment } from '../api/commercialFlowService'
import { accountedPaidCents } from './paymentAllocation'

export type PendingCommercialActionKind =
  | 'awaiting_response'
  | 'awaiting_approval'
  | 'awaiting_payment'
  | null

export type PendingCommercialAction = {
  kind: Exclude<PendingCommercialActionKind, null>
}

/** Display status after applying quote expiry (issued + past valid_until → expired). */
export function effectiveCommercialDocumentStatus(
  doc: Pick<CommercialDocument, 'status' | 'valid_until' | 'doc_type'>,
): string {
  if (
    doc.status === 'issued' &&
    doc.valid_until &&
    new Date(doc.valid_until).getTime() < Date.now() &&
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment')
  ) {
    return 'expired'
  }
  return doc.status
}

/** Terminal quote that can be superseded via `reissue_commercial_quote`. */
export function isCommercialQuoteReissuable(
  doc: Pick<CommercialDocument, 'doc_type' | 'status' | 'valid_until'>,
): boolean {
  if (doc.doc_type !== 'quote') return false
  const status = effectiveCommercialDocumentStatus(doc)
  return status === 'rejected' || status === 'expired' || status === 'cancelled'
}

/**
 * CF-14: pending staff/client action visible on the contact history without opening the doc.
 * Terminal statuses return null (status badge only).
 */
export function pendingCommercialAction(
  doc: CommercialDocument,
  paidCents?: number,
): PendingCommercialAction | null {
  const status = effectiveCommercialDocumentStatus(doc)

  if (
    status === 'rejected' ||
    status === 'expired' ||
    status === 'cancelled' ||
    status === 'draft'
  ) {
    return null
  }

  if (
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
    status === 'issued'
  ) {
    return {
      kind:
        doc.doc_type === 'quote_amendment'
          ? 'awaiting_approval'
          : 'awaiting_response',
    }
  }

  if (
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
    (status === 'accepted' || status === 'signed')
  ) {
    const totalCents = Math.round(Number(doc.total) * 100)
    const paid = paidCents ?? 0
    if (totalCents - paid > 0) {
      return { kind: 'awaiting_payment' }
    }
    return null
  }

  if (doc.doc_type === 'delivery_note') {
    const issued =
      status === 'issued' || status === 'signed' || status === 'accepted'
    if (!issued) return null
    const totalCents = Math.round(Number(doc.total) * 100)
    const paid = paidCents ?? 0
    if (totalCents - paid > 0) {
      return { kind: 'awaiting_payment' }
    }
  }

  return null
}

export function paidCentsByDocumentId(
  payments: { document_id: string; amount_cents: number }[],
): Map<string, number> {
  const map = new Map<string, number>()
  for (const payment of payments) {
    map.set(
      payment.document_id,
      (map.get(payment.document_id) ?? 0) + Number(payment.amount_cents ?? 0),
    )
  }
  return map
}

export function summarizeClientCommercialHistory(
  docs: CommercialDocument[],
  payments: Pick<CommercialPayment, 'document_id' | 'amount_cents'>[],
): {
  awaitingResponse: number
  awaitingApproval: number
  awaitingPayment: number
  total: number
} {
  let awaitingResponse = 0
  let awaitingApproval = 0
  let awaitingPayment = 0
  for (const doc of docs) {
    const pending = pendingCommercialAction(doc, accountedPaidCents(doc, docs, payments))
    if (pending?.kind === 'awaiting_response') awaitingResponse += 1
    if (pending?.kind === 'awaiting_approval') awaitingApproval += 1
    if (pending?.kind === 'awaiting_payment') awaitingPayment += 1
  }
  return {
    awaitingResponse,
    awaitingApproval,
    awaitingPayment,
    total: docs.length,
  }
}

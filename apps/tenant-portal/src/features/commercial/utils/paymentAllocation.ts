import type { CommercialDocument, CommercialPayment } from '../api/commercialFlowService'
import { sumPaymentsCents } from './paymentReceipt'

type PaymentLike = Pick<CommercialPayment, 'document_id' | 'amount_cents'>
type DocumentLike = Pick<
  CommercialDocument,
  | 'id'
  | 'doc_type'
  | 'project_id'
  | 'status'
  | 'total'
  | 'created_at'
  | 'issued_at'
  | 'supersedes_id'
>

const COLLECTABLE_DELIVERY = new Set(['issued', 'signed', 'accepted'])
const COLLECTABLE_ADVANCE = new Set(['accepted', 'signed'])

export function eurosToDocumentCents(total: number): number {
  return Math.max(0, Math.round(Number(total) * 100))
}

export function isAdvanceDocument(doc: Pick<DocumentLike, 'doc_type' | 'status'>): boolean {
  return (
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
    COLLECTABLE_ADVANCE.has(doc.status)
  )
}

export function isCollectableDelivery(doc: Pick<DocumentLike, 'doc_type' | 'status'>): boolean {
  return doc.doc_type === 'delivery_note' && COLLECTABLE_DELIVERY.has(doc.status)
}

function paymentsOn(documentId: string, payments: PaymentLike[]): CommercialPayment[] {
  return payments.filter((payment) => payment.document_id === documentId) as CommercialPayment[]
}

function deliverySortKey(doc: DocumentLike): string {
  return `${doc.issued_at ?? doc.created_at}\u0000${doc.id}`
}

function ancestorIds(doc: DocumentLike, documents: DocumentLike[]): string[] {
  const ids: string[] = []
  const seen = new Set<string>()
  let current = doc.supersedes_id
  while (current && !seen.has(current)) {
    seen.add(current)
    ids.push(current)
    current = documents.find((row) => row.id === current)?.supersedes_id ?? null
  }
  return ids
}

type DeliveryBalance = {
  ownPaidCents: number
  advanceAppliedCents: number
  remainingCents: number
}

function deliveryBalances(
  documents: DocumentLike[],
  payments: PaymentLike[],
): Map<string, DeliveryBalance> {
  const balances = new Map<string, DeliveryBalance>()
  const projects = new Set(
    documents
      .filter((doc) => doc.project_id && isCollectableDelivery(doc))
      .map((doc) => doc.project_id as string),
  )

  for (const projectId of projects) {
    const notes = documents
      .filter((doc) => doc.project_id === projectId && isCollectableDelivery(doc))
      .sort((a, b) => deliverySortKey(a).localeCompare(deliverySortKey(b)))
    let pool = advancePaidCentsForProject(projectId, documents, payments)
    for (const note of notes) {
      const ownPaidCents =
        sumPaymentsCents(paymentsOn(note.id, payments)) +
        ancestorIds(note, documents).reduce(
          (sum, id) => sum + sumPaymentsCents(paymentsOn(id, payments)),
          0,
        )
      const needCents = Math.max(0, eurosToDocumentCents(Number(note.total)) - ownPaidCents)
      const advanceAppliedCents = Math.min(needCents, pool)
      pool -= advanceAppliedCents
      balances.set(note.id, {
        ownPaidCents,
        advanceAppliedCents,
        remainingCents: needCents - advanceAppliedCents,
      })
    }
  }
  return balances
}

export function advanceAppliedCentsForDocument(
  target: DocumentLike,
  documents: DocumentLike[],
  payments: PaymentLike[],
): number {
  if (!isCollectableDelivery(target)) return 0
  return deliveryBalances(documents, payments).get(target.id)?.advanceAppliedCents ?? 0
}

export function advancePaidCentsForProject(
  projectId: string | null,
  documents: DocumentLike[],
  payments: PaymentLike[],
): number {
  if (!projectId) return 0
  return documents
    .filter((doc) => doc.project_id === projectId && isAdvanceDocument(doc))
    .reduce((sum, doc) => sum + sumPaymentsCents(paymentsOn(doc.id, payments)), 0)
}

export function allocatedPaidCents(
  target: DocumentLike,
  documents: DocumentLike[],
  payments: PaymentLike[],
): number {
  const own = sumPaymentsCents(paymentsOn(target.id, payments))
  if (target.doc_type === 'delivery_note') {
    const balance = deliveryBalances(documents, payments).get(target.id)
    if (!balance) return own
    return balance.ownPaidCents + balance.advanceAppliedCents
  }
  return own
}

export function remainingCentsForDocument(
  target: DocumentLike,
  documents: DocumentLike[],
  payments: PaymentLike[],
): number {
  if (target.doc_type === 'delivery_note') {
    if (!isCollectableDelivery(target)) return 0
    return deliveryBalances(documents, payments).get(target.id)?.remainingCents ?? 0
  }

  if (target.doc_type === 'quote' || target.doc_type === 'quote_amendment') {
    if (!isAdvanceDocument(target)) return 0
    const ownRemaining = Math.max(
      0,
      eurosToDocumentCents(Number(target.total)) -
        sumPaymentsCents(paymentsOn(target.id, payments)),
    )
    const openDeliveries = documents.filter(
      (doc) => doc.project_id === target.project_id && isCollectableDelivery(doc),
    )
    if (openDeliveries.length === 0) return ownRemaining
    const openCents = openDeliveries.reduce(
      (sum, doc) => sum + remainingCentsForDocument(doc, documents, payments),
      0,
    )
    return Math.max(0, Math.min(ownRemaining, openCents))
  }

  return 0
}

export function accountedPaidCents(
  target: DocumentLike,
  documents: DocumentLike[],
  payments: PaymentLike[],
): number {
  const collectable = isAdvanceDocument(target) || isCollectableDelivery(target)
  if (!collectable) {
    return allocatedPaidCents(target, documents, payments)
  }
  return Math.max(
    0,
    eurosToDocumentCents(Number(target.total)) -
      remainingCentsForDocument(target, documents, payments),
  )
}

export function canCollectDocument(
  target: DocumentLike,
  documents: DocumentLike[],
  payments: PaymentLike[],
): boolean {
  return remainingCentsForDocument(target, documents, payments) > 0
}

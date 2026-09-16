import type { CommercialDocument, CommercialPayment } from '../api/commercialFlowService'
import { sumPaymentsCents } from './paymentReceipt'

type PaymentLike = Pick<CommercialPayment, 'document_id' | 'amount_cents'>
type DocumentLike = Pick<
  CommercialDocument,
  'id' | 'doc_type' | 'project_id' | 'status' | 'total' | 'created_at'
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

function newestDelivery(documents: DocumentLike[], projectId: string | null): DocumentLike | undefined {
  if (!projectId) return undefined
  return [...documents]
    .filter((doc) => doc.project_id === projectId && isCollectableDelivery(doc))
    .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())[0]
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
    return own + advancePaidCentsForProject(target.project_id, documents, payments)
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
    return Math.max(
      0,
      eurosToDocumentCents(Number(target.total)) -
        allocatedPaidCents(target, documents, payments),
    )
  }

  if (target.doc_type === 'quote' || target.doc_type === 'quote_amendment') {
    if (!isAdvanceDocument(target)) return 0
    const ownRemaining = Math.max(
      0,
      eurosToDocumentCents(Number(target.total)) -
        allocatedPaidCents(target, documents, payments),
    )
    const latestDelivery = newestDelivery(documents, target.project_id)
    if (!latestDelivery) return ownRemaining
    return Math.max(
      0,
      Math.min(
        ownRemaining,
        remainingCentsForDocument(latestDelivery, documents, payments),
      ),
    )
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

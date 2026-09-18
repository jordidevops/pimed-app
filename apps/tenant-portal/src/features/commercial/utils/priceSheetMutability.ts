import { effectiveCommercialDocumentStatus } from './pendingCommercialAction'

export type PriceSheetDocType = 'quote' | 'quote_amendment' | 'delivery_note'

export type PriceSheetDocument = {
  id: string
  doc_type: PriceSheetDocType
  status: string
  valid_until?: string | null
}

export type PriceSheetLockReason = 'quote_in_progress' | null

export type PriceSheetMutability = {
  /** Hide add / habitual / AI / copy / delete / edit when true. */
  structureLocked: boolean
  lockReason: PriceSheetLockReason
  blockingDocument: PriceSheetDocument | null
  /** Accepted/signed quote or amendment without an issued pending lock. */
  showAcceptedBanner: boolean
  acceptedDocument: PriceSheetDocument | null
  canEditPricing: boolean
  /** Structure actions (add/delete/copy/habitual/AI). Not gated on pricing.edit. */
  canMutateStructure: boolean
}

function isQuoteLike(doc: PriceSheetDocument): boolean {
  return doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment'
}

/** Issued quote/amendment that is not past valid_until. */
export function findActiveIssuedQuoteLike(
  documents: PriceSheetDocument[],
): PriceSheetDocument | null {
  const issued = documents.filter((document) => {
    if (!isQuoteLike(document)) return false
    return effectiveCommercialDocumentStatus(document) === 'issued'
  })
  return issued[0] ?? null
}

export function findAcceptedOrSignedQuoteLike(
  documents: PriceSheetDocument[],
): PriceSheetDocument | null {
  return (
    documents.find((document) => {
      if (!isQuoteLike(document)) return false
      const status = effectiveCommercialDocumentStatus(document)
      return status === 'accepted' || status === 'signed'
    }) ?? null
  )
}

/**
 * When the price sheet structure may be mutated and which banners to show.
 * Does not hide habitual/copy/AI/add when the user lacks commercial.pricing.edit —
 * those paths work at catalog PVP without the permission.
 */
export function resolvePriceSheetMutability(input: {
  documents: PriceSheetDocument[]
  canEditPricing: boolean
  hasWaiver?: boolean
}): PriceSheetMutability {
  const blockingDocument = findActiveIssuedQuoteLike(input.documents)
  const acceptedDocument = findAcceptedOrSignedQuoteLike(input.documents)
  const structureLocked = !!blockingDocument

  return {
    structureLocked,
    lockReason: structureLocked ? 'quote_in_progress' : null,
    blockingDocument,
    showAcceptedBanner: !structureLocked && !!acceptedDocument,
    acceptedDocument,
    canEditPricing: input.canEditPricing,
    canMutateStructure: !structureLocked,
  }
}

/** Waiver CTA: no active issued quote/amendment and no accepted/signed one. */
export function canShowQuoteWaiverCta(documents: PriceSheetDocument[]): boolean {
  if (findActiveIssuedQuoteLike(documents)) return false
  if (findAcceptedOrSignedQuoteLike(documents)) return false
  return true
}

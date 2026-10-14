export type PrimaryCommercialDocLike = {
  id: string
  doc_type: string
  status: string
  created_at: string
  issued_at?: string | null
  valid_until?: string | null
  doc_number?: string | null
}

function newestFirst<T extends { created_at: string }>(docs: T[]): T[] {
  return [...docs].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
  )
}

function isQuoteLike(doc: PrimaryCommercialDocLike): boolean {
  return doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment'
}

function isEffectivelyExpired(
  doc: { status: string; valid_until?: string | null },
  nowMs: number,
): boolean {
  if (doc.status === 'expired') return true
  if (doc.status !== 'issued' || !doc.valid_until) return false
  const until = new Date(doc.valid_until).getTime()
  return Number.isFinite(until) && until < nowMs
}

/**
 * Single source of truth for “which quote/amendment” to surface on OS chrome,
 * authorize CTAs, and trail nav.
 *
 * Prefer accepted/signed → issued non-expired → newest actionable → newest any.
 */
export function resolvePrimaryCommercialDoc<T extends PrimaryCommercialDocLike>(
  documents: T[],
  nowMs = Date.now(),
): T | null {
  const quoteLike = newestFirst(documents.filter(isQuoteLike))
  if (quoteLike.length === 0) return null

  const accepted = quoteLike.find(
    (doc) => doc.status === 'accepted' || doc.status === 'signed',
  )
  if (accepted) return accepted

  const activeIssued = quoteLike.find(
    (doc) => doc.status === 'issued' && !isEffectivelyExpired(doc, nowMs),
  )
  if (activeIssued) return activeIssued

  const actionable = quoteLike.find((doc) => {
    if (isEffectivelyExpired(doc, nowMs)) return false
    return (
      doc.status === 'draft' ||
      doc.status === 'issued' ||
      doc.status === 'accepted' ||
      doc.status === 'signed'
    )
  })
  if (actionable) return actionable

  return quoteLike[0] ?? null
}

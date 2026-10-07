export type CommercialDecisionSendCta =
  | 'send_for_accept'
  | 'view_pending'
  | 'deliver_only'
  | 'issue'
  | 'none'

export function commercialDecisionRequestsEnabled(
  tenantSettings: Record<string, unknown> | null | undefined,
): boolean {
  const commercial = tenantSettings?.commercial
  if (!commercial || typeof commercial !== 'object') return false
  return (commercial as { decision_requests_enabled?: unknown }).decision_requests_enabled === true
}

export function commercialDecisionSendCta(params: {
  docStatus: string | null | undefined
  formalizationMode: string | null | undefined
  hasOpenRequest: boolean
  decisionRequestsEnabled: boolean
  /** Quote validity already expired (UI-derived). */
  isExpired?: boolean
  /** Active agreement version status when formalization is separate_agreement. */
  agreementVersionStatus?: string | null
  /** Whether the active agreement version has a rendered DMS document. */
  agreementRendered?: boolean
}): CommercialDecisionSendCta {
  if (!params.decisionRequestsEnabled) return 'none'
  if (params.docStatus === 'draft') return 'issue'

  const separate = params.formalizationMode === 'separate_agreement'
  if (separate) {
    // CS-D8: quote may stay issued until the agreement is signed; legacy rows may already be accepted.
    if (params.docStatus !== 'issued' && params.docStatus !== 'accepted') return 'none'
    if (params.isExpired) return 'none'
    if (params.hasOpenRequest) return 'view_pending'
    const ready =
      !!params.agreementRendered &&
      (params.agreementVersionStatus === 'draft' ||
        params.agreementVersionStatus === 'pending_signature')
    return ready ? 'send_for_accept' : 'none'
  }

  if (params.docStatus !== 'issued') return 'none'
  if (params.isExpired) return 'none'
  if (params.hasOpenRequest) return 'view_pending'
  return 'send_for_accept'
}

export function maskEmailForDisplay(email: string): string {
  const trimmed = email.trim()
  const at = trimmed.indexOf('@')
  if (at <= 0) return '***'
  const local = trimmed.slice(0, at)
  const domain = trimmed.slice(at + 1)
  if (!domain) return '***'
  return `${local.slice(0, 1)}***@${domain}`
}

export function commercialDecisionEmailIdempotencyKey(
  requestId: string,
  deliveryId: string,
): string {
  return `commercial-decision:${requestId}:delivery:${deliveryId}`
}

export function defaultDecisionExpiresAt(days = 14): string {
  const d = new Date()
  d.setDate(d.getDate() + days)
  return d.toISOString()
}

export function buildCommercialDecisionShareText(params: {
  title: string
  docNumber: string | null
  url: string
}): string {
  const number = params.docNumber?.trim() || '—'
  return `${params.title} ${number}\n${params.url}`.trim()
}

export function commercialDecisionActionForDocType(
  docType: string | null | undefined,
): 'accept' | 'delivery' {
  return docType === 'delivery_note' ? 'delivery' : 'accept'
}

export type CommercialNativeSignAction = 'accept' | 'reject' | 'delivery'

/** Rols que poden estampar el PDF. El refús no en té (CF-28 F5). */
export type CommercialNativeSignerRole = 'client_accept' | 'client_delivery'

export function commercialSignerRoleForAction(
  action: Exclude<CommercialNativeSignAction, 'reject'>,
): CommercialNativeSignerRole {
  if (action === 'delivery') return 'client_delivery'
  return 'client_accept'
}

export function buildCommercialNativeSignaturePayload(params: {
  action: Exclude<CommercialNativeSignAction, 'reject'>
  sessionId: string
  submissionId?: string | null
  signingGroupId?: string | null
  reason?: string | null
}): Record<string, unknown> {
  return {
    method: 'native',
    signing_session_id: params.sessionId,
    ...(params.submissionId ? { signing_submission_id: params.submissionId } : {}),
    ...(params.signingGroupId ? { signing_group_id: params.signingGroupId } : {}),
    ...(params.reason?.trim() ? { reason: params.reason.trim() } : {}),
    role: commercialSignerRoleForAction(params.action),
  }
}

export function commercialNativeSignLink(tokenOrUrl: string): string {
  const value = tokenOrUrl.trim()
  if (value.startsWith('http://') || value.startsWith('https://')) return value
  const origin =
    typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5173'
  return `${origin.replace(/\/$/, '')}/sign/${value}`
}

/** Trigger QT-9 already applied the commercial event with the same client_op_id. */
export function isAlreadyAppliedCommercialSigningError(err: unknown): boolean {
  const message =
    err instanceof Error
      ? err.message
      : typeof err === 'object' && err !== null && 'message' in err
        ? String((err as { message?: unknown }).message ?? '')
        : String(err ?? '')
  return (
    message.includes('document_not_issuable_state') ||
    message.includes('document_not_rejectable_state')
  )
}

export function buildCommercialSigningLinkShareText(params: {
  title: string
  docNumber: string | null
  signUrl: string
}): string {
  const number = params.docNumber?.trim() || '—'
  return `${params.title} ${number}\n${params.signUrl}`.trim()
}

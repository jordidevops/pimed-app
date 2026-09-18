export type CommercialNativeSignAction = 'accept' | 'reject' | 'delivery'

export type CommercialNativeSignerRole =
  | 'client_accept'
  | 'client_reject'
  | 'client_delivery'

export function commercialSignerRoleForAction(
  action: CommercialNativeSignAction,
): CommercialNativeSignerRole {
  if (action === 'reject') return 'client_reject'
  if (action === 'delivery') return 'client_delivery'
  return 'client_accept'
}

export function buildCommercialNativeSignaturePayload(params: {
  action: CommercialNativeSignAction
  submissionId: string
  sessionId: string
  signingGroupId?: string | null
  reason?: string | null
}): Record<string, unknown> {
  return {
    method: 'native',
    signing_submission_id: params.submissionId,
    signing_session_id: params.sessionId,
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

export function buildCommercialSigningLinkShareText(params: {
  title: string
  docNumber: string | null
  signUrl: string
}): string {
  const number = params.docNumber?.trim() || '—'
  return `${params.title} ${number}\n${params.signUrl}`.trim()
}

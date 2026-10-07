import type { SigningSubmission } from '@/features/signing/api/signingService'
import { supabase } from '@/lib/supabase'

type SignerRow = {
  role?: string
  email?: string
  status?: string
  order?: number
}

function parseSigners(raw: unknown): SignerRow[] {
  if (!Array.isArray(raw)) return []
  return raw as SignerRow[]
}

function isPendingSigner(s: SignerRow): boolean {
  const status = (s.status ?? '').toLowerCase()
  return status !== 'completed' && status !== 'signed'
}

/** True when the current user matches a pending employee/self signer (no URL exposed). */
export function isCurrentUserPendingSigner(
  submission: SigningSubmission | null | undefined,
  userEmail?: string | null,
): boolean {
  const signers = parseSigners(submission?.signers)
  if (!signers.length) return false

  const emailLower = userEmail?.trim().toLowerCase()
  if (!emailLower) return false

  for (const s of signers) {
    const emailMatch = s.email?.toLowerCase() === emailLower
    if (emailMatch && isPendingSigner(s)) {
      return true
    }
  }
  return false
}

/**
 * CS-D58 §4: own pending signing URL via SECURITY DEFINER RPC (never from api.signing_submissions).
 */
export async function fetchMyPendingSigningUrl(
  submissionId: string | null | undefined,
): Promise<string | null> {
  if (!submissionId) return null
  const { data, error } = await supabase.rpc('get_my_pending_signing_url', {
    p_submission_id: submissionId,
  })
  if (error) throw error
  return typeof data === 'string' && data.length > 0 ? data : null
}

/** @deprecated Prefer fetchMyPendingSigningUrl — list views no longer carry signing_url. */
export function resolveEmployeeSignerLink(
  _submission: SigningSubmission | null | undefined,
  _userEmail?: string | null,
): string | null {
  return null
}

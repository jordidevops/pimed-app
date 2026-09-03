import type { SigningSubmission } from '@/features/signing/api/signingService'

type SignerRow = {
  role?: string
  email?: string
  signing_url?: string | null
  status?: string
  order?: number
}

function parseSigners(raw: unknown): SignerRow[] {
  if (!Array.isArray(raw)) return []
  return raw as SignerRow[]
}

function isPendingSigner(s: SignerRow): boolean {
  const status = (s.status ?? '').toLowerCase()
  return status !== 'completed' && status !== 'signed' && !!s.signing_url
}

/** URL de signatura per al rol Empleat o el correu de l'usuari actual. */
export function resolveEmployeeSignerLink(
  submission: SigningSubmission | null | undefined,
  userEmail?: string | null,
): string | null {
  const signers = parseSigners(submission?.signers)
  if (!signers.length) return null

  const emailLower = userEmail?.trim().toLowerCase()

  for (const s of signers) {
    const role = (s.role ?? '').toLowerCase()
    const isEmployeeRole =
      role === 'empleat' || role === 'employee' || role === 'treballador' || role === 'worker'
    const emailMatch = emailLower && s.email?.toLowerCase() === emailLower
    if ((isEmployeeRole || emailMatch) && isPendingSigner(s)) {
      return s.signing_url!
    }
  }

  const sorted = [...signers].sort((a, b) => (a.order ?? 0) - (b.order ?? 0))
  const firstPending = sorted.find(isPendingSigner)
  return firstPending?.signing_url ?? null
}

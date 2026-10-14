export type SignerProgressStatus =
  | 'completed'
  | 'declined'
  | 'cancelled'
  | 'opened'
  | 'pending'

export type SignerProgressRoleKey = 'issuer' | 'client' | 'other'

export type SignerProgressItem = {
  role: string
  roleKey: SignerProgressRoleKey
  status: SignerProgressStatus
  order: number
  name: string
}

type RawSigner = {
  name?: string | null
  email?: string | null
  role?: string | null
  status?: string | null
  order?: number | null
  completed_at?: string | null
}

export function signerEffectiveStatus(signer: RawSigner): SignerProgressStatus {
  if (signer.status === 'declined') return 'declined'
  if (signer.status === 'cancelled') return 'cancelled'
  if (
    signer.completed_at ||
    signer.status === 'completed' ||
    signer.status === 'signed'
  ) {
    return 'completed'
  }
  if (signer.status === 'opened') return 'opened'
  return 'pending'
}

export function signerRoleKey(role: string | null | undefined): SignerProgressRoleKey {
  if (role === 'issuer') return 'issuer'
  if (role === 'client' || role === 'client_accept' || role === 'client_delivery') {
    return 'client'
  }
  return 'other'
}

export function parseSignerProgress(signers: unknown): SignerProgressItem[] {
  if (!Array.isArray(signers)) return []
  return signers
    .map((raw, index) => {
      const signer = (raw ?? {}) as RawSigner
      const role = typeof signer.role === 'string' ? signer.role : ''
      return {
        role,
        roleKey: signerRoleKey(role),
        status: signerEffectiveStatus(signer),
        order: typeof signer.order === 'number' ? signer.order : index,
        name: signer.name?.trim() || signer.email?.trim() || '',
      }
    })
    .sort((a, b) => a.order - b.order)
}

export function signerProgressMark(status: SignerProgressStatus): string {
  if (status === 'completed') return '✓'
  if (status === 'declined') return '✕'
  if (status === 'cancelled') return '–'
  if (status === 'opened') return '◐'
  return '○'
}

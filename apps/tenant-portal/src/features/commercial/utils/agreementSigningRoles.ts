/**
 * Resolve agreement signer roles from template signing_roles_schema (CS-D6).
 * Supports both `{ roles: ["issuer","client"] }` and `{ issuer: {...}, client: {...} }`.
 */

export type AgreementSignerRole = 'issuer' | 'client'

export function parseAgreementSigningRoles(schema: unknown): AgreementSignerRole[] {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    return ['client']
  }
  const obj = schema as Record<string, unknown>
  if (Array.isArray(obj.roles)) {
    const roles = obj.roles
      .filter((r): r is string => typeof r === 'string')
      .map((r) => r.trim())
      .filter((r): r is AgreementSignerRole => r === 'issuer' || r === 'client')
    return roles.length > 0 ? uniqueRoles(roles) : ['client']
  }
  const fromKeys = Object.keys(obj).filter(
    (k): k is AgreementSignerRole => k === 'issuer' || k === 'client',
  )
  return fromKeys.length > 0 ? uniqueRoles(fromKeys) : ['client']
}

function uniqueRoles(roles: AgreementSignerRole[]): AgreementSignerRole[] {
  const out: AgreementSignerRole[] = []
  if (roles.includes('issuer')) out.push('issuer')
  if (roles.includes('client')) out.push('client')
  return out.length > 0 ? out : ['client']
}

export function buildAgreementSignersPayload(params: {
  roles: AgreementSignerRole[]
  issuerName: string
  clientName: string
  issuerEmail?: string | null
  clientEmail?: string | null
}): Array<{ email: string; name: string; role: string; order: number }> {
  const issuerLabel = params.issuerName.trim() || 'Representant'
  const clientLabel = params.clientName.trim() || 'Client'
  return params.roles.map((role, order) =>
    role === 'issuer'
      ? {
          email: params.issuerEmail?.trim() || '',
          name: issuerLabel,
          role: 'issuer',
          order,
        }
      : {
          email: params.clientEmail?.trim() || '',
          name: clientLabel,
          role: 'client',
          order,
        },
  )
}

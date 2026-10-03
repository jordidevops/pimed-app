import type { Session } from '@supabase/supabase-js'

/**
 * App metadata used for RBAC. Prefer claims injected by
 * `data.custom_access_token_hook` on the access token — they are not always
 * mirrored onto `session.user.app_metadata` (auth.users row).
 */
export function getSessionAppMetadata(
  session: Session | null | undefined,
): Record<string, unknown> {
  const fromUser = (session?.user?.app_metadata ?? {}) as Record<string, unknown>
  const fromJwt = readAppMetadataFromAccessToken(session?.access_token)
  if (!fromJwt) return fromUser
  return { ...fromUser, ...fromJwt }
}

export function readAppMetadataFromAccessToken(
  accessToken: string | null | undefined,
): Record<string, unknown> | null {
  if (!accessToken) return null
  const payload = decodeJwtPayload(accessToken)
  const meta = payload?.app_metadata
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) return null
  return meta as Record<string, unknown>
}

function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const part = token.split('.')[1]
  if (!part) return null
  try {
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/')
    const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4)
    const json =
      typeof atob === 'function'
        ? atob(padded)
        : Buffer.from(padded, 'base64').toString('utf8')
    const parsed = JSON.parse(json) as unknown
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null
    return parsed as Record<string, unknown>
  } catch {
    return null
  }
}

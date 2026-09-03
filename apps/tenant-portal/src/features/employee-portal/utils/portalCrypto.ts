function base64UrlEncode(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

/** Secret per a /e/{secret} — mai es persisteix en clar, només el hash a BD. */
export function generatePortalSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return base64UrlEncode(bytes)
}

/** SHA-256 → format bytea PostgREST (\xhex). */
export async function hashPortalSecretForRpc(secret: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret))
  const hex = Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
  return `\\x${hex}`
}

/** Hash PIN (EP3). EP2 session verificarà el mateix format. */
export async function hashPortalPin(pin: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(`employee-portal-pin:${pin}`),
  )
  const hex = Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
  return `sha256:${hex}`
}

export function isValidPortalPin(pin: string): boolean {
  return /^\d{4,6}$/.test(pin)
}

/**
 * Edge Functions in local Docker often return signed URLs with host
 * `kong:8000`, which the browser cannot resolve. Rewrite to the public API URL.
 * Applies to both upload (PUT) and download/preview (GET) signed URLs.
 */
export function publicStorageUploadUrl(uploadUrl: string): string {
  const publicBase = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.replace(/\/$/, '')
  if (!publicBase || !uploadUrl) return uploadUrl

  try {
    const parsed = new URL(uploadUrl)
    if (parsed.hostname !== 'kong' && parsed.hostname !== 'kong.local') {
      return uploadUrl
    }
    const base = new URL(publicBase)
    parsed.protocol = base.protocol
    parsed.host = base.host
    return parsed.toString()
  } catch {
    return uploadUrl.replace(/^https?:\/\/kong(?::\d+)?/i, publicBase)
  }
}

/** Alias — same rewrite for GET signed URLs. */
export const publicStorageUrl = publicStorageUploadUrl

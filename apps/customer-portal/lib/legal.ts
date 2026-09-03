import { createClient } from '@supabase/supabase-js'

/** Anon/publishable client for public RPCs only (no service_role). */
export function createCustomerPortalPublicClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!url || !key) {
    throw new Error('Missing NEXT_PUBLIC_SUPABASE_URL or publishable/anon key')
  }
  return createClient(url, key, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

export type ResolvedLegalDocument = {
  ok: boolean
  error?: string
  mode?: string
  code?: string
  locale?: string
  title?: string
  body_html?: string
  external_url?: string
  version_number?: number
  template_version?: number
  tenant_id?: string
}

/** Only https absolute URLs (blocks javascript:, data:, open redirects to relative paths). */
export function isSafeExternalLegalUrl(url: string | null | undefined): boolean {
  if (!url || typeof url !== 'string') return false
  const trimmed = url.trim()
  try {
    const parsed = new URL(trimmed)
    return parsed.protocol === 'https:'
  } catch {
    return false
  }
}

export async function resolvePublicLegalDocument(params: {
  code: string
  locale?: string
  tenantId?: string | null
  publicSiteSlug?: string | null
}): Promise<ResolvedLegalDocument> {
  const client = createCustomerPortalPublicClient()
  const { data, error } = await client.rpc('resolve_public_legal_document', {
    p_code: params.code,
    p_locale: params.locale ?? 'es',
    p_tenant_id: params.tenantId ?? null,
    p_public_site_slug: params.publicSiteSlug ?? null,
  })
  if (error) {
    return { ok: false, error: error.message }
  }
  return (data && typeof data === 'object' ? data : { ok: false }) as ResolvedLegalDocument
}

import { createPortalClient } from './supabase'

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
  const client = createPortalClient()
  const { data, error } = await client.rpc('resolve_public_legal_document' as never, {
    p_code: params.code,
    p_locale: params.locale ?? 'es',
    p_tenant_id: params.tenantId ?? null,
    p_public_site_slug: params.publicSiteSlug ?? null,
  } as never)
  if (error) return { ok: false, error: error.message }
  return (data && typeof data === 'object' ? data : { ok: false }) as ResolvedLegalDocument
}

/** Prefer Legal Center; fall back to legacy URL. */
export async function resolvePrivacyUrlForSite(params: {
  slug?: string | null
  tenantId?: string | null
  locale: string
  code?: string
  legacyUrl?: string | null
  /** Custom domains use `/{locale}/legal/...` (no slug prefix). */
  linkBase?: 'slug' | 'locale'
}): Promise<string | null> {
  const code = params.code ?? 'privacy_website'
  const slug = params.slug?.trim() || null
  const doc = await resolvePublicLegalDocument({
    code,
    locale: params.locale,
    publicSiteSlug: slug,
    tenantId: params.tenantId ?? null,
  })
  if (doc.ok && doc.mode === 'external_url' && doc.external_url) {
    return isSafeExternalLegalUrl(doc.external_url) ? doc.external_url : null
  }
  if (doc.ok && doc.mode !== 'external_url') {
    if (params.linkBase === 'locale') {
      return `/${params.locale}/legal/${code}`
    }
    if (!slug) return null
    return `/${slug}/${params.locale}/legal/${code}`
  }
  const legacy = params.legacyUrl?.trim() || null
  if (legacy && isSafeExternalLegalUrl(legacy)) return legacy
  if (legacy && legacy.startsWith('/')) return legacy
  return null
}

import type { ResolvedPublicSiteForEmployee } from '@/features/employee-portal/utils/resolvePublicSiteForEmployee'

const DEV_BASE = import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined
const SYSTEM_DOMAIN = import.meta.env.VITE_PUBLIC_PORTAL_SYSTEM_DOMAIN as string | undefined

export function buildPortalBaseUrl(
  resolved: Pick<
    ResolvedPublicSiteForEmployee,
    'canonical_domain' | 'slug' | 'portal_base_url' | 'tenant_slug'
  >,
  tenantSlugFallback: string,
): string {
  if (resolved.portal_base_url) {
    return resolved.portal_base_url.replace(/\/$/, '')
  }

  if (DEV_BASE) {
    return DEV_BASE.replace(/\/$/, '')
  }

  const slug = resolved.slug || tenantSlugFallback
  if (SYSTEM_DOMAIN && slug) {
    return `https://${slug}.public.${SYSTEM_DOMAIN}`
  }

  return 'http://localhost:3002'
}

export function buildEmployeePortalBootstrapUrl(
  secret: string,
  resolved: ResolvedPublicSiteForEmployee,
  tenantSlugFallback: string,
): string {
  const base = buildPortalBaseUrl(resolved, tenantSlugFallback)
  return `${base}/e/${encodeURIComponent(secret)}`
}

export function buildEmployeePortalPinResetUrl(
  secret: string,
  resolved: ResolvedPublicSiteForEmployee,
  tenantSlugFallback: string,
): string {
  const base = buildPortalBaseUrl(resolved, tenantSlugFallback)
  return `${base}/e/pin-reset/${encodeURIComponent(secret)}`
}

/** URL d'accés quan només es coneix el secret (p. ex. resultats batch sense domini publicat). */
export function buildEmployeePortalUrlFromSecret(
  secret: string,
  resolved?: Pick<
    ResolvedPublicSiteForEmployee,
    'canonical_domain' | 'slug' | 'portal_base_url' | 'tenant_slug'
  > | null,
  tenantSlugFallback = '',
): string {
  const base = buildPortalBaseUrl(
    {
      canonical_domain: resolved?.canonical_domain ?? null,
      slug: resolved?.slug ?? null,
      portal_base_url: resolved?.portal_base_url ?? null,
      tenant_slug: resolved?.tenant_slug ?? tenantSlugFallback,
    },
    tenantSlugFallback,
  )
  return `${base}/e/${encodeURIComponent(secret)}`
}

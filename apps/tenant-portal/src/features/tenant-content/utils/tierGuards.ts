import type { ResolvedPortalEntitlements } from '@/features/portal-entitlements'

export function isAdvancedEmployeeTier(entitlements: ResolvedPortalEntitlements | null | undefined) {
  return entitlements?.employee_portal?.cms_tier === 'advanced'
}

export function isAdvancedPublicTier(entitlements: ResolvedPortalEntitlements | null | undefined) {
  return entitlements?.public_portal?.cms_tier === 'advanced'
}

export function pagesUsedForSite(
  entitlements: ResolvedPortalEntitlements | null | undefined,
  publicSiteId: string | null | undefined,
): number {
  if (!publicSiteId || !entitlements?.public_portal?.pages_used_by_site) return 0
  return entitlements.public_portal.pages_used_by_site[publicSiteId] ?? 0
}

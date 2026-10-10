import { useTenant } from '@/contexts/TenantContext'

/**
 * Resolves which tenant operational site (`data.sites`) applies.
 * - Sidebar selection when set
 * - Unique visible site
 * - Otherwise null (caller may ask the user when sites.length > 1)
 */
export function resolveTenantSiteId(params: {
  selectedSiteId: string | null
  sites: Array<{ id: string }>
}): string | null {
  if (params.selectedSiteId) return params.selectedSiteId
  if (params.sites.length === 1) return params.sites[0]?.id ?? null
  return null
}

export function useSiteScope() {
  const { sites, selectedSiteId, setSelectedSiteId, isSingleSiteContext, canUseAllSites } =
    useTenant()

  const effectiveSiteId = resolveTenantSiteId({ selectedSiteId, sites })
  const needsSitePick = !effectiveSiteId && sites.length > 1
  const showSiteFilter = sites.length > 1

  return {
    sites,
    selectedSiteId,
    setSelectedSiteId,
    effectiveSiteId,
    needsSitePick,
    showSiteFilter,
    isSingleSiteContext,
    canUseAllSites,
  }
}

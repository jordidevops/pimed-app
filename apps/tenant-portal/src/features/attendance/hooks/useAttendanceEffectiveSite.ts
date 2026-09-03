import { useMemo } from 'react'
import { useTenant } from '@/contexts/TenantContext'

/** Site used for attendance dashboard when «Tots els locals» is selected. */
export function useAttendanceEffectiveSite() {
  const { selectedSiteId, sites, activeSite } = useTenant()

  return useMemo(() => {
    const effectiveSiteId = selectedSiteId ?? sites[0]?.id ?? null
    const effectiveSite = selectedSiteId ? activeSite : (sites[0] ?? null)
    const isAllSitesFallback = !selectedSiteId && sites.length > 0

    return { effectiveSiteId, effectiveSite, isAllSitesFallback }
  }, [selectedSiteId, sites, activeSite])
}

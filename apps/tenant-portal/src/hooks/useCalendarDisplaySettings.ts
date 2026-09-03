import { useMemo } from 'react'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from './useSettings'

export interface CalendarDisplaySettings {
  dateFormat: string
  /** JS day-of-week: 0=Sunday, 1=Monday, … 6=Saturday */
  weekStartsOn: number
  isLoading: boolean
}

export function useCalendarDisplaySettings(): CalendarDisplaySettings {
  const { activeTenant, selectedSiteId } = useTenant()
  const { data: effective = {}, isLoading } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: selectedSiteId },
    { enabled: !!activeTenant?.id },
  )

  return useMemo(() => {
    const isSite = !!selectedSiteId
    const dateFormat = String(
      isSite
        ? (effective.site_date_format ?? effective.default_date_format ?? 'dd/MM/yyyy')
        : (effective.default_date_format ?? 'dd/MM/yyyy'),
    )
    const weekStartsOn = Number(effective.week_starts_on ?? 1)
    return {
      dateFormat,
      weekStartsOn: Number.isFinite(weekStartsOn) ? weekStartsOn : 1,
      isLoading,
    }
  }, [effective, selectedSiteId, isLoading])
}

import { useMemo } from 'react'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { parseMonthlyCloseSettings } from './monthlyCloseSettings'

export function useMonthlyCloseSettings(siteId?: string | null) {
  const { activeTenant } = useTenant()

  const query = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: siteId ?? null },
    { enabled: !!activeTenant?.id },
  )

  const settings = useMemo(
    () => parseMonthlyCloseSettings(query.data),
    [query.data],
  )

  return {
    settings,
    isLoading: query.isLoading,
    error: query.error,
  }
}

import { useMemo } from 'react'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { parseOvertimePolicy } from './overtimeSettings'

export function useOvertimePolicy() {
  const { activeTenant } = useTenant()

  const query = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: null },
    { enabled: !!activeTenant?.id },
  )

  const policy = useMemo(() => parseOvertimePolicy(query.data), [query.data])

  return {
    policy,
    isLoading: query.isLoading,
    error: query.error,
  }
}

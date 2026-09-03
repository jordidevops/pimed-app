import { useMemo } from 'react'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { parseApprovalAssistSettings } from './approvalAssistSettings'

export function useApprovalAssistSettings(siteId?: string | null) {
  const { activeTenant } = useTenant()

  const query = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: siteId ?? null },
    { enabled: !!activeTenant?.id },
  )

  const settings = useMemo(
    () => parseApprovalAssistSettings(query.data),
    [query.data],
  )

  return {
    settings,
    isLoading: query.isLoading,
    error: query.error,
  }
}

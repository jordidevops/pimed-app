import { useEffect } from 'react'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { setObservabilityScope } from './system-error-tracker'

/** Injecta user_id i tenant_id al context Sentry quan canvien. */
export function SentryScopeSync() {
  const { user } = useAuth()
  const { activeTenant } = useTenant()

  useEffect(() => {
    setObservabilityScope({
      userId: user?.id ?? null,
      tenantId: activeTenant?.id ?? null,
    })
  }, [user?.id, activeTenant?.id])

  return null
}

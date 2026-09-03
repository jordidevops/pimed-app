import { useMemo } from 'react'
import { useAuth } from '@/contexts/AuthContext'
import { useTenants } from '@/hooks/useTenants'
import { Spinner } from './ui/Spinner'
import { NoInternalAccessPage } from '@/pages/NoInternalAccessPage'

function jwtHasInternalTenants(user: { app_metadata?: Record<string, unknown> } | null): boolean | null {
  if (!user) return null
  const meta = user.app_metadata ?? {}
  const tenants = meta.user_tenants
  if (tenants && typeof tenants === 'object' && !Array.isArray(tenants)) {
    return Object.keys(tenants as Record<string, unknown>).length > 0
  }
  // Claim absent → defer to live membership query
  return null
}

/**
 * CP-B0: bloqueja el tenant-portal si no hi ha cap membresia interna activa.
 * Combina claim JWT (ràpid) + query live a tenant_members / my_tenant.
 */
export function InternalMemberGate({ children }: { children: React.ReactNode }) {
  const { user, loading: authLoading } = useAuth()
  const { data: tenants = [], isLoading: tenantsLoading, isFetched } = useTenants(user?.id)

  const jwtOk = useMemo(() => jwtHasInternalTenants(user), [user])

  if (authLoading || (user && tenantsLoading && !isFetched)) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background">
        <Spinner />
      </div>
    )
  }

  if (!user) {
    return <>{children}</>
  }

  // Fast path: JWT already proves internal membership
  if (jwtOk === true) {
    return <>{children}</>
  }

  // Live check (also covers stale JWT with empty claim)
  if (isFetched && tenants.length === 0) {
    return <NoInternalAccessPage />
  }

  if (!isFetched || tenantsLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background">
        <Spinner />
      </div>
    )
  }

  return <>{children}</>
}

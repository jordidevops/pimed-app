import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'

type JwtTenantPermissions = {
  global_permissions?: string[]
  sites?: Record<string, { permissions?: string[] }>
}

function hasAttendanceManageInJwt(
  userPermissions: unknown,
  tenantId: string | null,
): boolean {
  if (!tenantId || !userPermissions || typeof userPermissions !== 'object') return false

  const tenant = (userPermissions as Record<string, JwtTenantPermissions>)[tenantId]
  if (!tenant) return false

  if (
    tenant.global_permissions?.includes('*') ||
    tenant.global_permissions?.includes('attendance.manage')
  ) {
    return true
  }

  for (const site of Object.values(tenant.sites ?? {})) {
    if (
      site.permissions?.includes('*') ||
      site.permissions?.includes('attendance.manage')
    ) {
      return true
    }
  }

  return false
}

/** Mateix criteri que les RPC del portal d'empleat (attendance.manage o rol manager+). */
export function useCanManageEmployeePortal(): boolean {
  const { session } = useAuth()
  const { selectedTenantId, activeTenant, activeRole, activeSiteRole } = useTenant()

  const tenantId = selectedTenantId ?? activeTenant?.id ?? null
  const globalRole = activeRole ?? activeTenant?.role ?? null

  if (['owner', 'manager'].includes(globalRole ?? '')) return true
  if (['owner', 'manager'].includes(activeSiteRole ?? '')) return true

  return hasAttendanceManageInJwt(
    session?.user?.app_metadata?.user_permissions,
    tenantId,
  )
}

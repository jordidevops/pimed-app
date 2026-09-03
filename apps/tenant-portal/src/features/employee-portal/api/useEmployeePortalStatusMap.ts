import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { supabase } from '@/lib/supabase'

export type EmployeePortalStatus = 'none' | 'invited' | 'visited'

export interface EmployeePortalStatusInfo {
  status: EmployeePortalStatus
  hasAccess: boolean
  hasAccessed: boolean
}

function isTokenCurrentlyActive(row: {
  is_active: boolean | null
  revoked_at: string | null
  expires_at: string | null
}): boolean {
  if (!row.is_active || row.revoked_at) return false
  if (row.expires_at && new Date(row.expires_at).getTime() <= Date.now()) return false
  return true
}

/** Mapa employee_id → estat d’accés al portal (enllaç actiu / ha entrat). */
export function useEmployeePortalStatusMap(enabled = true) {
  const { activeTenant } = useTenant()

  const query = useQuery({
    queryKey: ['employee-portal-status-map', activeTenant?.id ?? ''],
    enabled: enabled && !!activeTenant?.id,
    staleTime: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('employee_portal_tokens')
        .select('employee_id, is_active, revoked_at, expires_at, first_accessed_at, last_accessed_at')
        .eq('tenant_id', activeTenant!.id)

      if (error) throw error

      const map = new Map<string, EmployeePortalStatusInfo>()

      for (const row of data ?? []) {
        const employeeId = row.employee_id
        if (!employeeId) continue

        const active = isTokenCurrentlyActive(row)
        const accessed = Boolean(row.first_accessed_at || row.last_accessed_at)
        const prev = map.get(employeeId)

        const hasAccess = Boolean(prev?.hasAccess || active)
        const hasAccessed = Boolean(prev?.hasAccessed || accessed)
        const status: EmployeePortalStatus = !hasAccess
          ? 'none'
          : hasAccessed
            ? 'visited'
            : 'invited'

        map.set(employeeId, { status, hasAccess, hasAccessed })
      }

      return map
    },
  })

  return useMemo(
    () => ({
      statusByEmployeeId: query.data ?? new Map<string, EmployeePortalStatusInfo>(),
      isLoading: query.isLoading,
      error: query.error,
    }),
    [query.data, query.isLoading, query.error],
  )
}

export function portalStatusForEmployee(
  map: Map<string, EmployeePortalStatusInfo>,
  employeeId: string | null | undefined,
): EmployeePortalStatusInfo {
  if (!employeeId) {
    return { status: 'none', hasAccess: false, hasAccessed: false }
  }
  return map.get(employeeId) ?? { status: 'none', hasAccess: false, hasAccessed: false }
}

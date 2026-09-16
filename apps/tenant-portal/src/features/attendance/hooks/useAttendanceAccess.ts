import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { useMyEmployee } from '../api/useMyEmployee'

/**
 * Single source of truth for personal attendance access.
 * The database remains authoritative; this capability only controls navigation
 * and gives direct routes a useful explanation before an RPC is attempted.
 */
export function useAttendanceAccess() {
  const { activeTenant, tenantsLoading } = useTenant()
  const employeeQuery = useMyEmployee()
  const employeeSiteId = employeeQuery.data?.site_id ?? null
  const canPunchOwn = usePermission('attendance.punch_own', employeeSiteId)
  const canRequestAbsence = usePermission('absences.request', employeeSiteId)

  const ready = !tenantsLoading && !employeeQuery.isLoading
  const hasActiveEmployee = Boolean(employeeQuery.data)

  return {
    ready,
    tenant: activeTenant,
    employee: employeeQuery.data ?? null,
    employeeError: employeeQuery.error,
    hasActiveEmployee,
    canPunchOwn,
    canRequestAbsence,
    canUseAttendance: ready && Boolean(activeTenant) && hasActiveEmployee && canPunchOwn,
  }
}

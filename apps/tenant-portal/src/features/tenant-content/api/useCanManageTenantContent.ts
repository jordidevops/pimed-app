import { useCanManageEmployeePortal } from '@/features/employee-portal/api/useCanManageEmployeePortal'

/** Mateix criteri que el hub d'accés al portal (attendance.manage o rol manager+). */
export function useCanManageTenantContent(): boolean {
  return useCanManageEmployeePortal()
}

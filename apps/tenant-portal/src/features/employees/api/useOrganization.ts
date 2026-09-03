import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { getEmployeeDirectReports, getEmployeeOrgTree } from './organizationService'

export function useEmployeeOrgTree(
  rootEmployeeId?: string | null,
  maxDepth = 8,
  enabled = true,
) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employee-org-tree', activeTenant?.id ?? '', rootEmployeeId ?? 'roots', maxDepth],
    queryFn: () => getEmployeeOrgTree(rootEmployeeId, maxDepth),
    enabled: !!activeTenant?.id && enabled,
  })
}

export function useEmployeeDirectReports(employeeId?: string) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employee-direct-reports', activeTenant?.id ?? '', employeeId ?? ''],
    queryFn: () => getEmployeeDirectReports(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId,
  })
}

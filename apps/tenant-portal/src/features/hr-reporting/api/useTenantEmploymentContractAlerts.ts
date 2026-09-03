import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { listEmploymentContractAlerts } from '@/features/employees/api/employmentContractsService'

/** Tenant-wide EC-8 alerts (p_employee_id NULL). */
export function useTenantEmploymentContractAlerts(asOf?: string | null) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: [
      'employment-contract-alerts',
      activeTenant?.id ?? '',
      'tenant',
      asOf ?? '',
    ],
    enabled: !!activeTenant?.id,
    queryFn: () => listEmploymentContractAlerts(null, asOf ?? undefined),
    staleTime: 30_000,
  })
}

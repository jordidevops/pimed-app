import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { getEmployeeHrProfile, type EmployeeHrProfile } from './employeesService'

export function useEmployeeHrProfile(id?: string, enabled = true) {
  const { activeTenant } = useTenant()
  return useQuery<EmployeeHrProfile | null>({
    queryKey: ['employees', activeTenant?.id ?? '', 'hr-profile', id ?? ''],
    queryFn: () => getEmployeeHrProfile(id!),
    enabled: !!activeTenant?.id && !!id && enabled,
  })
}

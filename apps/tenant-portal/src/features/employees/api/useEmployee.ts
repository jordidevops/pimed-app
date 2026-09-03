import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { getEmployeeById, type Employee } from './employeesService'

export function useEmployee(id?: string) {
  const { activeTenant } = useTenant()
  return useQuery<Employee | null>({
    queryKey: ['employees', activeTenant?.id ?? '', 'detail', id ?? ''],
    queryFn: () => getEmployeeById(id!),
    enabled: !!activeTenant?.id && !!id,
  })
}

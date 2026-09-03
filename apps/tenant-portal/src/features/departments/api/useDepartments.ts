import { useQuery } from '@tanstack/react-query'
import { departmentsKeys } from './departmentsKeys'
import { getDepartments } from './departmentsService'
import type { Department } from './departmentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useDepartments() {
  const { activeTenant } = useTenant()

  return useQuery<Department[]>({
    queryKey: departmentsKeys.list(activeTenant?.id ?? ''),
    queryFn: getDepartments,
    enabled: !!activeTenant,
  })
}

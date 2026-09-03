import { useMutation, useQueryClient } from '@tanstack/react-query'
import { departmentsKeys } from './departmentsKeys'
import { createDepartment } from './departmentsService'
import type { CreateDepartmentParams } from './departmentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useCreateDepartment() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: (params: CreateDepartmentParams) => createDepartment(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: departmentsKeys.list(activeTenant?.id ?? ''),
      })
    },
  })
}

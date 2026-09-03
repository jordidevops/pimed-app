import { useMutation, useQueryClient } from '@tanstack/react-query'
import { departmentsKeys } from './departmentsKeys'
import { updateDepartment } from './departmentsService'
import type { UpdateDepartmentParams } from './departmentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useUpdateDepartment() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: UpdateDepartmentParams }) =>
      updateDepartment(id, params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: departmentsKeys.list(activeTenant?.id ?? ''),
      })
    },
  })
}

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { employeesKeys } from './employeesKeys'
import { updateEmployee, type UpdateEmployeeParams } from './employeesService'
import { useTenant } from '@/contexts/TenantContext'

export function useUpdateEmployee() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: UpdateEmployeeParams }) =>
      updateEmployee(id, params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: employeesKeys.all(activeTenant?.id ?? ''),
      })
      queryClient.invalidateQueries({ queryKey: ['employee-org-tree'] })
      queryClient.invalidateQueries({ queryKey: ['employee-direct-reports'] })
      queryClient.invalidateQueries({ queryKey: ['employees'] })
    },
  })
}

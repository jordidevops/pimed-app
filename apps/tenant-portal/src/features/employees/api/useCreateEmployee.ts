import { useMutation, useQueryClient } from '@tanstack/react-query'
import { employeesKeys } from './employeesKeys'
import { createEmployee, type CreateEmployeeParams } from './employeesService'
import { useTenant } from '@/contexts/TenantContext'

export function useCreateEmployee() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (params: CreateEmployeeParams) => createEmployee(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: employeesKeys.all(activeTenant?.id ?? ''),
      })
    },
  })
}

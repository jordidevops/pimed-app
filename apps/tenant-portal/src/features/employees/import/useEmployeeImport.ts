import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { employeesKeys } from '../api/employeesKeys'
import {
  importEmployeesBulk,
  listEmployeeExternalMappings,
} from './employeeImportApi'
import type { EmployeeImportRecord, ImportEmployeesOptions } from './employeeImportTypes'

export function useImportEmployeesBulk() {
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      rows,
      options,
    }: {
      rows: EmployeeImportRecord[]
      options?: ImportEmployeesOptions
    }) => importEmployeesBulk(rows, options),
    onSuccess: (_data, vars) => {
      if (!vars.options?.dry_run && activeTenant?.id) {
        void queryClient.invalidateQueries({ queryKey: employeesKeys.all(activeTenant.id) })
      }
    },
  })
}

export function employeeMappingsKey(tenantId: string, employeeId: string) {
  return [...employeesKeys.all(tenantId), 'external_mappings', employeeId] as const
}

export function useEmployeeExternalMappings(employeeId: string | undefined) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: employeeMappingsKey(activeTenant?.id ?? '', employeeId ?? ''),
    queryFn: () => listEmployeeExternalMappings(employeeId!),
    enabled: Boolean(activeTenant?.id && employeeId),
  })
}

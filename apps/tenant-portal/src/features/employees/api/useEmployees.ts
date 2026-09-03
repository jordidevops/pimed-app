import { useQuery } from '@tanstack/react-query'
import { employeesKeys } from './employeesKeys'
import { getEmployees } from './employeesService'
import type { Employee } from './employeesService'
import { useTenant } from '@/contexts/TenantContext'

/**
 * Directori d'empleats del tenant actiu (sense filtre de local al fetch).
 * L'abast de local el resol la UI (sidebar selectedSiteId + filtres de llista)
 * per evitar doble filtre i perquè pickers (signing, manager, etc.) vegin tot el tenant.
 */
export function useEmployees() {
  const { activeTenant, tenantScopeReady } = useTenant()
  return useQuery<Employee[]>({
    queryKey: employeesKeys.list(activeTenant?.id ?? ''),
    queryFn: () => getEmployees(),
    enabled: !!activeTenant && tenantScopeReady,
  })
}

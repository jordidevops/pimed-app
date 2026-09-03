import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { attendanceKeys } from './attendanceKeys'
import { getMyEmployee } from './attendanceService'
import type { Employee } from './attendanceService'

/**
 * Retorna l'empleat actiu associat a l'usuari autenticat per al tenant actiu.
 * Necessari per obtenir l'`employee_id` que s'usa a totes les operacions de fitxatge.
 */
export function useMyEmployee() {
  const { user } = useAuth()
  const { activeTenant } = useTenant()

  return useQuery<Employee | null>({
    queryKey: attendanceKeys.myEmployee(activeTenant?.id ?? ''),
    queryFn: () => getMyEmployee(user!.id, activeTenant!.id),
    enabled: !!user?.id && !!activeTenant?.id,
    staleTime: 5 * 60 * 1000, // 5 minuts — el registre d'empleat canvia poc
  })
}

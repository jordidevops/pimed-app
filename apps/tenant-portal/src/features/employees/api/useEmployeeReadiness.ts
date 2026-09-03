import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type EmployeeReadiness = {
  employee_id: string
  as_of: string
  is_ready: boolean
  blocking_reasons: string[]
  configuration_status: 'unconfigured' | 'partial' | 'configured'
}

export function useEmployeeReadiness(employeeId: string | undefined, asOf?: string | null) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['employee-readiness', tenantId, employeeId, asOf ?? null],
    enabled: tenantScopeReady && !!tenantId && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_employee_readiness' as never, {
        p_employee_id: employeeId,
        p_as_of: asOf ?? null,
        p_required_requirement_codes: null,
      } as never)
      if (error) throw error
      const raw = data as Record<string, unknown>
      return {
        employee_id: String(raw.employee_id),
        as_of: String(raw.as_of),
        is_ready: Boolean(raw.is_ready),
        blocking_reasons: Array.isArray(raw.blocking_reasons)
          ? (raw.blocking_reasons as string[])
          : [],
        configuration_status: raw.configuration_status as EmployeeReadiness['configuration_status'],
      } satisfies EmployeeReadiness
    },
  })
}

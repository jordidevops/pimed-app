import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type EmployeeDispatchStatus = {
  employee_id: string
  as_of: string
  is_eligible: boolean
  lifecycle_state: string
  blocking_reasons: string[]
  configuration_status: 'unconfigured' | 'partial' | 'configured' | string
}

export function useEmployeeDispatchStatus(employeeId: string | undefined, asOf?: string | null) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['employee-dispatch-status', tenantId, employeeId, asOf ?? null],
    enabled: tenantScopeReady && !!tenantId && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_employee_dispatch_status' as never, {
        p_employee_id: employeeId,
        p_as_of: asOf ?? null,
      } as never)
      if (error) throw error
      const raw = data as Record<string, unknown>
      return {
        employee_id: String(raw.employee_id),
        as_of: String(raw.as_of),
        is_eligible: Boolean(raw.is_eligible),
        lifecycle_state: String(raw.lifecycle_state),
        blocking_reasons: Array.isArray(raw.blocking_reasons)
          ? (raw.blocking_reasons as string[])
          : [],
        configuration_status: String(raw.configuration_status),
      } satisfies EmployeeDispatchStatus
    },
  })
}

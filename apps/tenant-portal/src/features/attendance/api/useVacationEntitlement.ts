import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface VacationEntitlement {
  found: boolean
  days_allocated: number
  days_used: number
  days_remaining: number
  scope?: string
}

export function useVacationEntitlement(employeeId: string | null, year: number) {
  return useQuery({
    queryKey: ['attendance', 'vacation-entitlement', employeeId, year],
    enabled: Boolean(employeeId),
    queryFn: async (): Promise<VacationEntitlement> => {
      const { data, error } = await supabase.rpc('get_vacation_entitlement', {
        p_employee_id: employeeId!,
        p_year: year,
        p_leave_type: 'vacation',
      })
      if (error) throw new Error(error.message)
      const raw = (data ?? {}) as Record<string, unknown>
      return {
        found: Boolean(raw.found),
        days_allocated: Number(raw.days_allocated ?? 0),
        days_used: Number(raw.days_used ?? 0),
        days_remaining: Number(raw.days_remaining ?? 0),
        scope: typeof raw.scope === 'string' ? raw.scope : undefined,
      }
    },
  })
}

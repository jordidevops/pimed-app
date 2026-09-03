import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type LifecycleEvent = {
  id: string
  tenant_id: string
  employee_id: string
  from_state: string | null
  to_state: string
  reason_code: string
  effective_on: string
  triggered_by: string | null
  source: string
  metadata: Record<string, unknown>
  created_at: string
}

export type LifecycleTransitionRule = {
  id: string
  from_state: string
  to_state: string
  requires_permission: string
  requires_reason: boolean
  auto_reason_codes: string[]
}

export function useEmployeeLifecycleEvents(employeeId: string | undefined) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['employee-lifecycle-events', tenantId, employeeId],
    enabled: tenantScopeReady && !!tenantId && !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('employee_lifecycle_events')
        .select('*')
        .eq('employee_id', employeeId!)
        .order('effective_on', { ascending: false })
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as LifecycleEvent[]
    },
  })
}

export function useLifecycleTransitionRules() {
  const { tenantScopeReady } = useTenant()
  return useQuery({
    queryKey: ['lifecycle-transition-rules'],
    enabled: tenantScopeReady,
    queryFn: async () => {
      const { data, error } = await supabase.from('employee_lifecycle_transition_rules').select('*')
      if (error) throw error
      return (data ?? []) as LifecycleTransitionRule[]
    },
  })
}

export function useTransitionEmployeeLifecycle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      employee_id: string
      to_state: string
      reason_code: string
      effective_on?: string
      metadata?: Record<string, unknown>
    }) => {
      const { data, error } = await supabase.rpc('transition_employee_lifecycle' as never, {
        p_employee_id: params.employee_id,
        p_to_state: params.to_state,
        p_reason_code: params.reason_code,
        p_effective_on: params.effective_on ?? null,
        p_metadata: params.metadata ?? {},
      } as never)
      if (error) throw error
      return data as LifecycleEvent
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-lifecycle-events'] })
      void qc.invalidateQueries({ queryKey: ['employee', vars.employee_id] })
      void qc.invalidateQueries({ queryKey: ['employees'] })
    },
  })
}

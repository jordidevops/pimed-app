import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export type AvailabilityPreference = 'preferred' | 'available' | 'unavailable'

export type AvailabilityRule = {
  id: string
  tenant_id: string
  employee_id: string
  day_of_week: number
  start_time: string
  end_time: string
  preference: AvailabilityPreference
  notes: string | null
  editable_until: string | null
  effective_from: string
  effective_to: string | null
  is_active: boolean
}

export type AvailabilityException = {
  id: string
  tenant_id: string
  employee_id: string
  exception_date: string
  start_time: string | null
  end_time: string | null
  preference: AvailabilityPreference
  notes: string | null
  editable_until: string | null
  is_active: boolean
}

function timeValue(raw: string | null | undefined): string {
  if (!raw) return ''
  return raw.length >= 5 ? raw.slice(0, 5) : raw
}

export function useEmployeeAvailabilityRules(employeeId: string | undefined) {
  return useQuery({
    queryKey: ['employee-availability-rules', employeeId],
    enabled: !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_availability_rules' as never, {
        p_employee_id: employeeId,
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return ((data ?? []) as AvailabilityRule[]).map((r) => ({
        ...r,
        start_time: timeValue(r.start_time),
        end_time: timeValue(r.end_time),
      }))
    },
  })
}

export function useEmployeeAvailabilityExceptions(employeeId: string | undefined) {
  return useQuery({
    queryKey: ['employee-availability-exceptions', employeeId],
    enabled: !!employeeId,
    queryFn: async () => {
      const from = new Date()
      from.setDate(from.getDate() - 7)
      const to = new Date()
      to.setDate(to.getDate() + 60)
      const iso = (d: Date) =>
        `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

      const { data, error } = await supabase.rpc('list_employee_availability_exceptions' as never, {
        p_employee_id: employeeId,
        p_from: iso(from),
        p_to: iso(to),
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return ((data ?? []) as AvailabilityException[]).map((x) => ({
        ...x,
        start_time: x.start_time ? timeValue(x.start_time) : null,
        end_time: x.end_time ? timeValue(x.end_time) : null,
      }))
    },
  })
}

export function useUpsertAvailabilityRule() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id?: string | null
      employee_id: string
      day_of_week: number
      start_time: string
      end_time: string
      preference: AvailabilityPreference
      notes?: string | null
      editable_until?: string | null
      effective_from?: string | null
      effective_to?: string | null
    }) => {
      const { data, error } = await supabase.rpc('upsert_employee_availability_rule' as never, {
        p_id: input.id ?? null,
        p_employee_id: input.employee_id,
        p_day_of_week: input.day_of_week,
        p_start_time: input.start_time,
        p_end_time: input.end_time,
        p_preference: input.preference,
        p_notes: input.notes ?? null,
        p_editable_until: input.editable_until ?? null,
        p_effective_from: input.effective_from ?? null,
        p_effective_to: input.effective_to ?? null,
        p_is_active: true,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-availability-rules', vars.employee_id] })
    },
  })
}

export function useDeactivateAvailabilityRule() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { id: string; employee_id: string }) => {
      const { data, error } = await supabase.rpc('deactivate_employee_availability_rule' as never, {
        p_id: input.id,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-availability-rules', vars.employee_id] })
    },
  })
}

export function useUpsertAvailabilityException() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id?: string | null
      employee_id: string
      exception_date: string
      start_time?: string | null
      end_time?: string | null
      preference: AvailabilityPreference
      notes?: string | null
      all_day?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_employee_availability_exception' as never, {
        p_id: input.id ?? null,
        p_employee_id: input.employee_id,
        p_exception_date: input.exception_date,
        p_start_time: input.all_day ? null : (input.start_time ?? null),
        p_end_time: input.all_day ? null : (input.end_time ?? null),
        p_preference: input.preference,
        p_notes: input.notes ?? null,
        p_editable_until: null,
        p_is_active: true,
        p_clear_times: input.all_day ?? false,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-availability-exceptions', vars.employee_id] })
    },
  })
}

export function useDeactivateAvailabilityException() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { id: string; employee_id: string }) => {
      const { data, error } = await supabase.rpc('deactivate_employee_availability_exception' as never, {
        p_id: input.id,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-availability-exceptions', vars.employee_id] })
    },
  })
}

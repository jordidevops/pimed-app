import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type WorkRole = {
  id: string
  tenant_id: string
  site_id: string | null
  key: string
  name: string
  sort_order: number
  is_active: boolean
}

export type RoleQualRequirement = {
  id: string
  role_id: string
  qualification_key: string
  required: boolean
  min_level: number | null
  is_active: boolean
}

export type EmployeeRoleAssignment = {
  id: string
  employee_id: string
  role_id: string
  role_key: string
  role_name: string
  level: number
  valid_from: string | null
  valid_to: string | null
  is_primary: boolean
  is_active: boolean
}

export type EmployeeQualification = {
  id: string
  employee_id: string
  key: string
  label: string
  issued_at: string | null
  expires_at: string | null
  notes: string | null
  is_active: boolean
}

export function useWorkRoles(siteId?: string | null) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id
  return useQuery({
    queryKey: ['work-roles', tenantId, siteId ?? null],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_work_roles' as never, {
        p_site_id: siteId ?? null,
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return (data ?? []) as WorkRole[]
    },
  })
}

export function useUpsertWorkRole() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      id?: string | null
      site_id?: string | null
      key?: string
      name: string
      sort_order?: number
    }) => {
      const { data, error } = await supabase.rpc('upsert_work_role' as never, {
        p_id: params.id ?? null,
        p_site_id: params.site_id ?? null,
        p_key: params.key ?? null,
        p_name: params.name,
        p_sort_order: params.sort_order ?? 100,
        p_is_active: true,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['work-roles'] })
    },
  })
}

export function useDeactivateWorkRole() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('deactivate_work_role' as never, { p_id: id } as never)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['work-roles'] })
    },
  })
}

export function useRoleQualRequirements(roleId: string | null) {
  return useQuery({
    queryKey: ['role-qual-reqs', roleId],
    enabled: !!roleId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_role_qualification_requirements' as never, {
        p_role_id: roleId,
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return (data ?? []) as RoleQualRequirement[]
    },
  })
}

export function useUpsertRoleQualRequirement() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      id?: string | null
      role_id: string
      qualification_key: string
      required?: boolean
      min_level?: number | null
    }) => {
      const { error } = await supabase.rpc('upsert_role_qualification_requirement' as never, {
        p_id: params.id ?? null,
        p_role_id: params.role_id,
        p_qualification_key: params.qualification_key,
        p_required: params.required ?? true,
        p_min_level: params.min_level ?? null,
        p_is_active: true,
      } as never)
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['role-qual-reqs', vars.role_id] })
    },
  })
}

export function useDeactivateRoleQualRequirement() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: { id: string; role_id: string }) => {
      const { error } = await supabase.rpc('deactivate_role_qualification_requirement' as never, {
        p_id: params.id,
      } as never)
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['role-qual-reqs', vars.role_id] })
    },
  })
}

export function useEmployeeRoleAssignments(employeeId: string | undefined) {
  return useQuery({
    queryKey: ['employee-role-assignments', employeeId],
    enabled: !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_role_assignments' as never, {
        p_employee_id: employeeId,
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return (data ?? []) as EmployeeRoleAssignment[]
    },
  })
}

export function useEmployeeQualifications(employeeId: string | undefined) {
  return useQuery({
    queryKey: ['employee-qualifications', employeeId],
    enabled: !!employeeId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_qualifications' as never, {
        p_employee_id: employeeId,
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return (data ?? []) as EmployeeQualification[]
    },
  })
}

export function useUpsertEmployeeRoleAssignment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      employee_id: string
      role_id: string
      level?: number
      is_primary?: boolean
    }) => {
      const { error } = await supabase.rpc('upsert_employee_role_assignment' as never, {
        p_id: null,
        p_employee_id: params.employee_id,
        p_role_id: params.role_id,
        p_level: params.level ?? 1,
        p_valid_from: null,
        p_valid_to: null,
        p_is_primary: params.is_primary ?? false,
        p_is_active: true,
      } as never)
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-role-assignments', vars.employee_id] })
    },
  })
}

export function useDeactivateEmployeeRoleAssignment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: { id: string; employee_id: string }) => {
      const { error } = await supabase.rpc('deactivate_employee_role_assignment' as never, {
        p_id: params.id,
      } as never)
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-role-assignments', vars.employee_id] })
    },
  })
}

export function useUpsertEmployeeQualification() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      employee_id: string
      key?: string
      label: string
      expires_at?: string | null
    }) => {
      const { error } = await supabase.rpc('upsert_employee_qualification' as never, {
        p_id: null,
        p_employee_id: params.employee_id,
        p_key: params.key ?? null,
        p_label: params.label,
        p_issued_at: null,
        p_expires_at: params.expires_at ?? null,
        p_notes: null,
        p_is_active: true,
      } as never)
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-qualifications', vars.employee_id] })
    },
  })
}

export function useDeactivateEmployeeQualification() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: { id: string; employee_id: string }) => {
      const { error } = await supabase.rpc('deactivate_employee_qualification' as never, {
        p_id: params.id,
      } as never)
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: ['employee-qualifications', vars.employee_id] })
    },
  })
}

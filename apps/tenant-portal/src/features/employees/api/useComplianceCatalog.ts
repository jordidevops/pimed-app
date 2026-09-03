import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type ComplianceRequirementType = {
  id: string
  tenant_id: string | null
  code: string
  name: string
  category: 'legal' | 'medical' | 'technical' | 'other'
  default_validity_months: number | null
  renewal_notice_days: number[]
  is_active: boolean
  created_at: string
  updated_at: string
}

export type ComplianceRequirementRule = {
  id: string
  tenant_id: string
  requirement_type_id: string
  scope_type: 'tenant' | 'department' | 'job_position' | 'site'
  scope_id: string | null
  is_blocking: boolean
  grace_period_days: number
  is_active: boolean
  created_by: string
  created_at: string
  updated_at: string
}

export function useComplianceRequirementTypes(includeInactive = false) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['compliance-requirement-types', tenantId, includeInactive],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_compliance_requirement_types' as never, {
        p_include_inactive: includeInactive,
      } as never)
      if (error) throw error
      return (data ?? []) as ComplianceRequirementType[]
    },
  })
}

export function useComplianceRequirementRules(includeInactive = false) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['compliance-requirement-rules', tenantId, includeInactive],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_compliance_requirement_rules' as never, {
        p_include_inactive: includeInactive,
      } as never)
      if (error) throw error
      return (data ?? []) as ComplianceRequirementRule[]
    },
  })
}

export function useUpsertComplianceRequirementType() {
  const qc = useQueryClient()

  return useMutation({
    mutationFn: async (params: {
      id?: string | null
      code?: string
      name: string
      category: ComplianceRequirementType['category']
      default_validity_months?: number | null
      renewal_notice_days?: number[]
      is_active?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_compliance_requirement_type' as never, {
        p_id: params.id ?? null,
        p_code: params.code ?? null,
        p_name: params.name,
        p_category: params.category,
        p_default_validity_months: params.default_validity_months ?? null,
        p_renewal_notice_days: params.renewal_notice_days ?? null,
        p_is_active: params.is_active ?? true,
      } as never)
      if (error) throw error
      return data as ComplianceRequirementType
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['compliance-requirement-types'] })
    },
  })
}

export function useUpsertComplianceRequirementRule() {
  const qc = useQueryClient()

  return useMutation({
    mutationFn: async (params: {
      id?: string | null
      requirement_type_id: string
      scope_type: ComplianceRequirementRule['scope_type']
      scope_id?: string | null
      is_blocking?: boolean
      grace_period_days?: number
      is_active?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_compliance_requirement_rule' as never, {
        p_id: params.id ?? null,
        p_requirement_type_id: params.requirement_type_id,
        p_scope_type: params.scope_type,
        p_scope_id: params.scope_id ?? null,
        p_is_blocking: params.is_blocking ?? true,
        p_grace_period_days: params.grace_period_days ?? 0,
        p_is_active: params.is_active ?? true,
      } as never)
      if (error) throw error
      return data as ComplianceRequirementRule
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['compliance-requirement-rules'] })
    },
  })
}

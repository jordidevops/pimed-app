import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export type LaborRuleKey =
  | 'min_rest_between_shifts_hours'
  | 'max_daily_hours'
  | 'max_consecutive_work_days'

export type LaborRuleSeverity = 'info' | 'warn_require_reason' | 'block'

export type LaborRuleRow = {
  id: string | null
  tenant_id: string
  site_id: string | null
  rule_key: LaborRuleKey
  value_numeric: number
  severity: LaborRuleSeverity
  is_active: boolean
  source: 'configured' | 'product_default'
  created_at: string | null
  updated_at: string | null
}

export type LaborRulesListResponse = {
  tenant_id: string
  site_id: string | null
  rules: LaborRuleRow[]
}

const QUERY_KEY = ['labor-rules'] as const

export const LABOR_RULE_META: Record<
  LaborRuleKey,
  { label: string; hint: string; unit: string }
> = {
  min_rest_between_shifts_hours: {
    label: 'Descans mínim entre torns',
    hint: 'Hores mínimes entre el final d’un torn i l’inici del següent. Defecte de producte: 11 h.',
    unit: 'h',
  },
  max_daily_hours: {
    label: 'Màxim d’hores diàries',
    hint: 'Suma d’hores de torns el mateix dia. Defecte de producte: 12 h.',
    unit: 'h',
  },
  max_consecutive_work_days: {
    label: 'Màxim de dies consecutius',
    hint: 'Dies seguits amb almenys un torn. Defecte de producte: 6.',
    unit: 'dies',
  },
}

export function useLaborRules(siteId: string | null = null) {
  return useQuery({
    queryKey: [...QUERY_KEY, siteId],
    queryFn: async (): Promise<LaborRulesListResponse> => {
      const { data, error } = await supabase.rpc('list_labor_rules' as never, {
        p_site_id: siteId,
      } as never)
      if (error) throw error
      const payload = data as LaborRulesListResponse
      return {
        tenant_id: payload.tenant_id,
        site_id: payload.site_id ?? null,
        rules: (payload.rules ?? []) as LaborRuleRow[],
      }
    },
  })
}

export function useUpsertLaborRule() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      ruleKey: LaborRuleKey
      valueNumeric: number
      severity: LaborRuleSeverity
      siteId?: string | null
      isActive?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_labor_rule' as never, {
        p_rule_key: input.ruleKey,
        p_value_numeric: input.valueNumeric,
        p_severity: input.severity,
        p_site_id: input.siteId ?? null,
        p_is_active: input.isActive ?? true,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: QUERY_KEY })
    },
  })
}

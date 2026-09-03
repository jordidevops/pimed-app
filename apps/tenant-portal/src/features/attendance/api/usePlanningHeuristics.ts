import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export type FatigueAlert = {
  code: string
  employee_id: string
  employee_name: string
  actual_days?: number
  actual_hours?: number
  rule_limit: number
  explanation: string
}

export type EquityEmployee = {
  employee_id: string
  employee_name: string
  hours: number
  weekend_shifts: number
  night_shifts: number
  delta_vs_avg_hours: number
  explanation: string
}

export type DowPattern = {
  day_of_week: number
  absence_count?: number
  employee_count?: number
  late_count?: number
  explanation: string
}

export type GapRiskTomorrow = {
  date: string
  risk_level: 'none' | 'medium' | 'high' | string
  required_target_sum: number
  planned_slots: number
  open_vacancy_places: number
  gap: number
  explanation: string
  reinforce_suggestions: { kind: string; message: string }[]
}

export type PlanningHeuristics = {
  ok: boolean
  site_id: string
  as_of: string
  lookback_days: number
  disclaimer: string
  fatigue_alerts: FatigueAlert[]
  equity_snapshot: {
    window_days: number
    site_avg_hours: number
    employees: EquityEmployee[]
  }
  absence_patterns: DowPattern[]
  late_patterns: DowPattern[]
  gap_risk_tomorrow: GapRiskTomorrow
}

const DOW_LABELS = ['Dg', 'Dl', 'Dt', 'Dc', 'Dj', 'Dv', 'Ds']

export function dowLabel(dow: number): string {
  return DOW_LABELS[dow] ?? String(dow)
}

export function usePlanningHeuristics(siteId: string | null | undefined, asOf?: string) {
  return useQuery({
    queryKey: ['planning-heuristics', siteId, asOf ?? null],
    enabled: !!siteId,
    queryFn: async (): Promise<PlanningHeuristics> => {
      const { data, error } = await supabase.rpc('get_site_planning_heuristics' as never, {
        p_site_id: siteId,
        p_as_of: asOf ?? null,
        p_lookback_days: 28,
      } as never)
      if (error) throw error
      const raw = data as PlanningHeuristics
      return {
        ...raw,
        fatigue_alerts: raw.fatigue_alerts ?? [],
        equity_snapshot: {
          window_days: raw.equity_snapshot?.window_days ?? 28,
          site_avg_hours: Number(raw.equity_snapshot?.site_avg_hours ?? 0),
          employees: raw.equity_snapshot?.employees ?? [],
        },
        absence_patterns: raw.absence_patterns ?? [],
        late_patterns: raw.late_patterns ?? [],
        gap_risk_tomorrow: raw.gap_risk_tomorrow,
      }
    },
  })
}

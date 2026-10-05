import { supabase } from '@/lib/supabase'

export type ProjectProfitabilitySummary = {
  project_id: string
  currency: string
  revenue: {
    estimated_cents: number
    real_cents: number
    billed_cents: number
    real_basis: 'accepted_subtotal' | 'lines' | string
  }
  cost: {
    lines_cents: number
    materials_cents: number
    labor_cents: number
    expenses_cents: number
    total_cents: number
  }
  gross: {
    estimated_cents: number
    real_cents: number
  }
  coverage: {
    lines_missing_cost: number
    materials_missing_cost: number
    /** Closed logs with cost_method=unavailable OR missing freeze row. */
    labor_unavailable_logs: number
    open_work_logs: number
    hour_lines_excluded: number
  }
}

export async function getProjectProfitabilitySummary(
  projectId: string,
): Promise<ProjectProfitabilitySummary> {
  const { data, error } = await supabase.rpc('get_project_profitability_summary', {
    p_project_id: projectId,
  })
  if (error) throw error
  return data as unknown as ProjectProfitabilitySummary
}

export function centsToEuroNumber(cents: number): number {
  return cents / 100
}

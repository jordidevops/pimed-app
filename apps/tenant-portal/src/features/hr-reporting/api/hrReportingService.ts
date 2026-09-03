import { supabase } from '@/lib/supabase'

export type HrBreakdownRow = {
  site_id?: string | null
  department_id?: string | null
  job_position_id?: string | null
  name: string
  count: number
}

export type HrReportingSummary = {
  as_of: string
  period_days: number
  period_from: string
  site_id?: string | null
  department_id?: string | null
  site_scoped: boolean
  definitions?: Record<string, string>
  headcount: {
    effective: number
    legacy_without_contract: number
  }
  hires: number
  terminations: number
  by_site: HrBreakdownRow[]
  by_department: HrBreakdownRow[]
  by_job_position: HrBreakdownRow[]
  contracts_by_status: Record<string, number>
  contracts_expiring_90d: number
  incomplete_profiles: number
  onboarding_count: number
  onboardings_blocked: number | null
}

export async function getHrReportingSummary(params?: {
  asOf?: string | null
  periodDays?: number
  siteId?: string | null
  departmentId?: string | null
}): Promise<HrReportingSummary> {
  const { data, error } = await supabase.rpc('get_hr_reporting_summary', {
    p_as_of: params?.asOf ?? undefined,
    p_period_days: params?.periodDays ?? 30,
    p_site_id: params?.siteId || undefined,
    p_department_id: params?.departmentId || undefined,
  })
  if (error) throw error
  const raw = (data ?? {}) as Record<string, unknown>
  const headcount = (raw.headcount ?? {}) as Record<string, unknown>
  return {
    as_of: String(raw.as_of ?? ''),
    period_days: Number(raw.period_days ?? 30),
    period_from: String(raw.period_from ?? ''),
    site_id: (raw.site_id as string | null) ?? null,
    department_id: (raw.department_id as string | null) ?? null,
    site_scoped: Boolean(raw.site_scoped),
    definitions: (raw.definitions as Record<string, string>) ?? undefined,
    headcount: {
      effective: Number(headcount.effective ?? 0),
      legacy_without_contract: Number(headcount.legacy_without_contract ?? 0),
    },
    hires: Number(raw.hires ?? 0),
    terminations: Number(raw.terminations ?? 0),
    by_site: Array.isArray(raw.by_site) ? (raw.by_site as HrBreakdownRow[]) : [],
    by_department: Array.isArray(raw.by_department)
      ? (raw.by_department as HrBreakdownRow[])
      : [],
    by_job_position: Array.isArray(raw.by_job_position)
      ? (raw.by_job_position as HrBreakdownRow[])
      : [],
    contracts_by_status:
      (raw.contracts_by_status as Record<string, number>) ?? {},
    contracts_expiring_90d: Number(raw.contracts_expiring_90d ?? 0),
    incomplete_profiles: Number(raw.incomplete_profiles ?? 0),
    onboarding_count: Number(raw.onboarding_count ?? 0),
    onboardings_blocked:
      raw.onboardings_blocked == null ? null : Number(raw.onboardings_blocked),
  }
}

import { supabase } from '@/lib/supabase'

export interface LegalCounterLimits {
  statutory_overtime_minutes: number
  convenio_overtime_minutes: number | null
  statutory_work_minutes: number | null
}

export interface LegalCounterPct {
  statutory_overtime: number | null
  convenio_overtime: number | null
  statutory_work: number | null
}

export interface LegalCounterRow {
  period_key: string
  work_minutes_ytd: number
  travel_minutes_ytd: number
  paid_minutes_ytd: number
  effective_minutes_ytd: number
  overtime_authorized_ytd: number
  overtime_pending_ytd: number
  limits: LegalCounterLimits
  pct: LegalCounterPct
}

export interface AttendanceLegalCounters {
  employee_id: string
  as_of_date: string
  period_type: string
  compensation_balance_minutes: number
  counters: LegalCounterRow[]
}

export interface SiteLegalRiskEmployee {
  employee_id: string
  employee_name: string | null
  overtime_authorized_ytd: number
  overtime_pending_ytd: number
  paid_minutes_ytd: number
  pct_statutory_overtime: number
}

export interface SiteLegalRiskResult {
  site_id: string
  period_key: string
  threshold_pct: number
  employees: SiteLegalRiskEmployee[]
}

export async function fetchAttendanceLegalCounters(
  employeeId: string,
  asOfDate?: string,
): Promise<AttendanceLegalCounters> {
  const { data, error } = await supabase.rpc('get_attendance_legal_counters' as never, {
    p_employee_id: employeeId,
    p_as_of_date: asOfDate ?? null,
  } as never)

  if (error) throw error
  return data as AttendanceLegalCounters
}

export async function fetchSiteLegalRiskEmployees(
  siteId: string,
  thresholdPct = 80,
): Promise<SiteLegalRiskResult> {
  const { data, error } = await supabase.rpc('list_site_legal_risk_employees' as never, {
    p_site_id: siteId,
    p_threshold_pct: thresholdPct,
  } as never)

  if (error) throw error
  return data as SiteLegalRiskResult
}

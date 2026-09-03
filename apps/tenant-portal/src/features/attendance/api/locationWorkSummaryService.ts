import { supabase } from '@/lib/supabase'
import type { LocationWorkSummaryRow } from '../utils/locationWorkSummary'

export interface SummarizeLocationWorkParams {
  siteId: string
  from: string
  to: string
  employeeId?: string | null
  locationId?: string | null
}

export interface SummarizeLocationWorkResult {
  ok: boolean
  site_id: string
  from: string
  to: string
  timezone: string
  rows: LocationWorkSummaryRow[]
}

export async function summarizeLocationWork(
  params: SummarizeLocationWorkParams,
): Promise<SummarizeLocationWorkResult> {
  const { data, error } = await supabase.rpc('summarize_location_work', {
    p_site_id: params.siteId,
    p_from: params.from,
    p_to: params.to,
    p_employee_id: params.employeeId ?? undefined,
    p_location_id: params.locationId ?? undefined,
  })
  if (error) throw error

  const payload = (data ?? {}) as Record<string, unknown>
  const rawRows = (payload.rows ?? []) as Array<Record<string, unknown>>

  return {
    ok: Boolean(payload.ok),
    site_id: String(payload.site_id ?? params.siteId),
    from: String(payload.from ?? params.from),
    to: String(payload.to ?? params.to),
    timezone: String(payload.timezone ?? 'Europe/Madrid'),
    rows: rawRows.map((row) => ({
      employee_id: String(row.employee_id ?? ''),
      employee_name: String(row.employee_name ?? ''),
      location_id: (row.location_id as string | null) ?? null,
      location_name: String(row.location_name ?? 'Sense ubicació'),
      work_minutes: Number(row.work_minutes ?? 0),
      interval_count: Number(row.interval_count ?? 0),
      open_interval_count: Number(row.open_interval_count ?? 0),
    })),
  }
}

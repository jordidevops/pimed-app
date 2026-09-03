import { supabase } from '@/lib/supabase'
import type { PunchDiscrepancyResolution } from '../utils/punchDiscrepancyUtils'

export interface SubmitPunchDiscrepancyParams {
  punchId: string
  resolution: PunchDiscrepancyResolution
  note?: string | null
  context?: Record<string, unknown>
}

export interface SubmitPunchDiscrepancyResult {
  success: boolean
  geoStripped?: boolean
  error?: string
}

export async function submitPunchDiscrepancy(
  params: SubmitPunchDiscrepancyParams,
): Promise<SubmitPunchDiscrepancyResult> {
  const { data, error } = await supabase.rpc('submit_punch_discrepancy' as never, {
    p_punch_id: params.punchId,
    p_resolution: params.resolution,
    p_note: params.note ?? undefined,
    p_context: params.context ?? {},
  } as never)

  if (error) {
    return { success: false, error: error.message }
  }

  const result = data as { status?: string; geo_stripped?: boolean }
  return {
    success: result.status === 'submitted',
    geoStripped: result.geo_stripped,
  }
}

export interface PunchRecordedContext {
  punchType: 'in' | 'out' | 'break_start' | 'break_end'
  punchId?: string
  anomalyCodes: string[]
  occurredAt: string
  hadGeo: boolean
  status: string
}

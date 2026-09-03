import { supabase } from '@/lib/supabase'

export type ProtocolBulkScope = 'all_active' | 'site' | 'calendar_group'

export interface ProtocolBulkEnqueueResult {
  job_id: string
  total_count: number
  scope: string
}

export interface ProtocolBulkJobStatus {
  id: string
  tenant_id: string
  scope: string
  status: 'queued' | 'processing' | 'completed' | 'partial' | 'failed'
  total_count: number
  succeeded_count: number
  failed_count: number
  skipped_count: number
  error_summary: Array<{ employee_id?: string; error?: string; at?: string }>
  started_at: string | null
  completed_at: string | null
  created_at: string
  failed_items: Array<{
    id: string
    employee_id: string
    status: string
    error_message: string | null
    processed_at: string | null
  }>
}

export async function enqueueProtocolBulkPublish(params: {
  scope: ProtocolBulkScope
  siteId?: string | null
  calendarGroupId?: string | null
}): Promise<ProtocolBulkEnqueueResult> {
  const { data, error } = await supabase.rpc('enqueue_attendance_protocol_bulk_publish' as never, {
    p_scope: params.scope,
    p_site_id: params.scope === 'site' ? params.siteId ?? null : null,
    p_calendar_group_id: params.scope === 'calendar_group' ? params.calendarGroupId ?? null : null,
  } as never)

  if (error) throw new Error(error.message)
  return data as ProtocolBulkEnqueueResult
}

export async function getProtocolBulkJob(jobId: string): Promise<ProtocolBulkJobStatus> {
  const { data, error } = await supabase.rpc('get_attendance_protocol_bulk_job' as never, {
    p_job_id: jobId,
  } as never)

  if (error) throw new Error(error.message)
  return data as ProtocolBulkJobStatus
}

export function isProtocolBulkJobFinished(status: ProtocolBulkJobStatus['status']): boolean {
  return status === 'completed' || status === 'partial' || status === 'failed'
}

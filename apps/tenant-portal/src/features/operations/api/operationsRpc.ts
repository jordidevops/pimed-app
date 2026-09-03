import { supabase } from '../../../lib/supabase'

export type OperationLogStatus =
  | 'pending'
  | 'running'
  | 'success'
  | 'failed'
  | 'dead_letter'
  | 'cancelled'
  | 'degraded'

export type OperationIntegrationType =
  | 'email'
  | 'sms'
  | 'push'
  | 'webhook_inbound'
  | 'webhook_outbound'
  | 'erp_sync'
  | 'signing'
  | 'pdf_generation'
  | 'ai_generation'
  | 'ai_chat'
  | 'import'
  | 'export'
  | 'storage'
  | 'geocoding'
  | 'billing'
  | 'other'

export type OperationLogItem = {
  id: string
  integration_type: OperationIntegrationType
  operation_code: string
  status: OperationLogStatus
  title: string
  message: string | null
  error_code: string | null
  error_message: string | null
  duration_ms: number | null
  duration_threshold_ms: number | null
  external_service: string | null
  is_retryable: boolean
  resolved_at: string | null
  created_at: string
  completed_at: string | null
  payload_summary: Record<string, unknown>
  correlation_id: string | null
}

export type OperationLogsPage = {
  items: OperationLogItem[]
  total: number
  limit: number
  offset: number
}

export async function fetchUnresolvedOperationCount(
  tenantId: string,
  since?: string | null,
): Promise<number> {
  const { data, error } = await supabase.rpc('get_unresolved_operation_count', {
    p_tenant_id: tenantId,
    p_since: since ?? undefined,
  })
  if (error) throw error
  return Number(data ?? 0)
}

export async function fetchTenantOperationLogs(params: {
  tenantId: string
  status?: OperationLogStatus | null
  integrationType?: OperationIntegrationType | null
  limit?: number
  offset?: number
}): Promise<OperationLogsPage> {
  const { data, error } = await supabase.rpc('get_tenant_operation_logs', {
    p_tenant_id: params.tenantId,
    p_status: params.status ?? undefined,
    p_integration_type: params.integrationType ?? undefined,
    p_limit: params.limit ?? 50,
    p_offset: params.offset ?? 0,
  })
  if (error) throw error

  const payload = (data ?? { items: [], total: 0, limit: 50, offset: 0 }) as OperationLogsPage
  return {
    items: Array.isArray(payload.items) ? payload.items : [],
    total: Number(payload.total ?? 0),
    limit: Number(payload.limit ?? 50),
    offset: Number(payload.offset ?? 0),
  }
}

export async function markOperationLogResolved(
  tenantId: string,
  logId: string,
  note?: string,
): Promise<boolean> {
  const { data, error } = await supabase.rpc('mark_operation_log_resolved', {
    p_tenant_id: tenantId,
    p_log_id: logId,
    p_note: note ?? undefined,
  })
  if (error) throw error
  return Boolean(data)
}

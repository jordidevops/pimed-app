import { supabase } from '@/lib/supabase'
import { buildEmployeePortalUrlFromSecret } from '../utils/portalUrl'
import type {
  FetchPortalTokenBatchResults,
  PortalTokenBatchListItem,
  PortalTokenBatchResultRow,
  PortalTokenBatchSummary,
  StartPortalTokenBatchInput,
  StartPortalTokenBatchResult,
} from './employeePortalBatchTypes'

const IDEMPOTENCY_STORAGE_KEY = 'ep_portal_batch_idempotency'
const PENDING_BATCH_STORAGE_KEY = 'ep_portal_batch_pending'

export type PortalTokenBatchErrorCode =
  | 'batch_too_large'
  | 'batch_empty'
  | 'batch_expired'
  | 'batch_not_found'
  | 'batch_not_completed'
  | 'batch_rate_limited'
  | 'idempotency_key_exhausted'
  | 'unauthorized'
  | 'generic'

export function normalizePortalTokenBatchError(error: unknown): PortalTokenBatchErrorCode {
  const message =
    typeof error === 'object' && error !== null && 'message' in error
      ? String((error as { message?: string }).message ?? '')
      : ''

  if (message.includes('batch_too_large')) return 'batch_too_large'
  if (message.includes('batch_rate_limited')) return 'batch_rate_limited'
  if (message.includes('batch_expired')) return 'batch_expired'
  if (message.includes('batch_not_found')) return 'batch_not_found'
  if (message.includes('batch_not_completed')) return 'batch_not_completed'
  if (message.includes('idempotency_key_exhausted')) return 'idempotency_key_exhausted'
  if (message.includes('insufficient_privilege') || message.includes('42501')) {
    return 'unauthorized'
  }
  if (message.includes('batch_empty')) return 'batch_empty'
  return 'generic'
}

function mapStartResult(data: Record<string, unknown>): StartPortalTokenBatchResult {
  const summary = (data.summary as Record<string, number> | undefined) ?? {}
  return {
    batchId: String(data.batch_id),
    status: data.status as StartPortalTokenBatchResult['status'],
    expiresAt: String(data.expires_at),
    summary: {
      requested: summary.requested ?? 0,
      created: summary.created ?? 0,
      skipped: summary.skipped ?? 0,
      errors: summary.errors ?? 0,
    },
    idempotentReplay: Boolean(data.idempotent_replay),
  }
}

function mapResultRow(row: Record<string, unknown>): PortalTokenBatchResultRow {
  return {
    employeeId: String(row.employee_id),
    employeeName: row.employee_name != null ? String(row.employee_name) : null,
    employeeCode: row.employee_code != null ? String(row.employee_code) : null,
    status: row.status as PortalTokenBatchResultRow['status'],
    errorCode: row.error_code != null ? String(row.error_code) : null,
    portalUrl: row.portal_url != null ? String(row.portal_url) : null,
    secret: row.secret != null ? String(row.secret) : null,
    tokenId: row.token_id != null ? String(row.token_id) : null,
    supersededTokenId:
      row.superseded_token_id != null ? String(row.superseded_token_id) : null,
    label: row.label != null ? String(row.label) : null,
  }
}

export function createBatchIdempotencyKey(): string {
  const key = crypto.randomUUID()
  sessionStorage.setItem(IDEMPOTENCY_STORAGE_KEY, key)
  return key
}

export function getStoredBatchIdempotencyKey(): string | null {
  return sessionStorage.getItem(IDEMPOTENCY_STORAGE_KEY)
}

export function clearStoredBatchIdempotencyKey(): void {
  sessionStorage.removeItem(IDEMPOTENCY_STORAGE_KEY)
}

export function savePendingPortalBatch(batchId: string, expiresAt: string): void {
  const payload = JSON.stringify({ batchId, expiresAt })
  sessionStorage.setItem(PENDING_BATCH_STORAGE_KEY, payload)
}

export function loadPendingPortalBatch(): { batchId: string; expiresAt: string } | null {
  const raw = sessionStorage.getItem(PENDING_BATCH_STORAGE_KEY)
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as { batchId?: string; expiresAt?: string }
    if (!parsed.batchId || !parsed.expiresAt) return null
    if (new Date(parsed.expiresAt).getTime() <= Date.now()) {
      sessionStorage.removeItem(PENDING_BATCH_STORAGE_KEY)
      return null
    }
    return { batchId: parsed.batchId, expiresAt: parsed.expiresAt }
  } catch {
    sessionStorage.removeItem(PENDING_BATCH_STORAGE_KEY)
    return null
  }
}

export function clearPendingPortalBatch(): void {
  sessionStorage.removeItem(PENDING_BATCH_STORAGE_KEY)
}

export async function startEmployeePortalTokenBatch(
  input: StartPortalTokenBatchInput,
): Promise<StartPortalTokenBatchResult> {
  const { data, error } = await supabase.rpc('start_employee_portal_token_batch', {
    p_idempotency_key: input.idempotencyKey,
    p_employee_ids: input.employeeIds,
    p_pin_must_set: input.pinMustSet,
    p_label: input.label?.trim() || undefined,
    p_skip_inactive: input.skipInactive ?? true,
    p_force_new: input.forceNew ?? false,
  })

  if (error) throw error
  if (!data || typeof data !== 'object') throw new Error('missing_batch_start_payload')

  return mapStartResult(data as Record<string, unknown>)
}

export async function fetchEmployeePortalTokenBatchResults(
  batchId: string,
): Promise<FetchPortalTokenBatchResults> {
  const { data, error } = await supabase.rpc('fetch_employee_portal_token_batch_results', {
    p_batch_id: batchId,
  })

  if (error) throw error
  if (!data || typeof data !== 'object') throw new Error('missing_batch_fetch_payload')

  const payload = data as Record<string, unknown>
  const rows = Array.isArray(payload.rows)
    ? (payload.rows as Record<string, unknown>[]).map(mapResultRow)
    : []

  return {
    batchId: String(payload.batch_id),
    expiresAt: String(payload.expires_at),
    rows,
  }
}

export async function listEmployeePortalTokenBatches(
  limit = 10,
): Promise<PortalTokenBatchListItem[]> {
  const { data, error } = await supabase.rpc('list_employee_portal_token_batches', {
    p_limit: limit,
  })

  if (error) throw error

  const batches = (data as { batches?: Record<string, unknown>[] } | null)?.batches ?? []
  return batches.map((item) => ({
    batchId: String(item.batch_id),
    status: String(item.status),
    expiresAt: String(item.expires_at),
    label: item.label != null ? String(item.label) : null,
    employeeCount: Number(item.employee_count ?? 0),
    createdCount: Number(item.created_count ?? 0),
    skippedCount: Number(item.skipped_count ?? 0),
    errorCount: Number(item.error_count ?? 0),
    createdAt: String(item.created_at),
    lastFetchedAt: item.last_fetched_at != null ? String(item.last_fetched_at) : null,
    fetchCount: Number(item.fetch_count ?? 0),
  }))
}

export function resolveBatchRowPortalUrl(row: PortalTokenBatchResultRow): string | null {
  if (row.portalUrl) return row.portalUrl
  if (!row.secret) return null
  return buildEmployeePortalUrlFromSecret(row.secret)
}

function summarizeBatchResults(rows: PortalTokenBatchResultRow[]): PortalTokenBatchSummary {
  return {
    requested: rows.length,
    created: rows.filter((r) => r.status === 'created').length,
    skipped: rows.filter((r) => r.status === 'skipped').length,
    errors: rows.filter((r) => r.status === 'error').length,
  }
}

export async function recoverEmployeePortalTokenBatch(
  batchId: string,
  expiresAt: string,
): Promise<{
  start: StartPortalTokenBatchResult
  results: FetchPortalTokenBatchResults
}> {
  const results = await fetchEmployeePortalTokenBatchResults(batchId)
  savePendingPortalBatch(batchId, expiresAt)
  return {
    start: {
      batchId,
      status: 'completed',
      expiresAt,
      summary: summarizeBatchResults(results.rows),
      idempotentReplay: true,
    },
    results,
  }
}

export interface AckPortalTokenBatchResult {
  batchId: string
  status: string
  alreadyAcked: boolean
}

export async function ackEmployeePortalTokenBatch(
  batchId: string,
): Promise<AckPortalTokenBatchResult> {
  const { data, error } = await supabase.rpc('ack_employee_portal_token_batch', {
    p_batch_id: batchId,
  })

  if (error) throw error
  if (!data || typeof data !== 'object') throw new Error('missing_batch_ack_payload')

  const payload = data as Record<string, unknown>
  return {
    batchId: String(payload.batch_id),
    status: String(payload.status),
    alreadyAcked: Boolean(payload.already_acked),
  }
}

export async function runEmployeePortalTokenBatch(
  input: StartPortalTokenBatchInput,
): Promise<{
  start: StartPortalTokenBatchResult
  results: FetchPortalTokenBatchResults | null
}> {
  const start = await startEmployeePortalTokenBatch(input)
  if (start.status !== 'completed') {
    return { start, results: null }
  }

  const results = await fetchEmployeePortalTokenBatchResults(start.batchId)
  savePendingPortalBatch(start.batchId, start.expiresAt)
  clearStoredBatchIdempotencyKey()
  return { start, results }
}

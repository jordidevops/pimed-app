import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'
import {
  buildSyncPunchBatchItem,
  type SyncPunchBatchItem,
  type SyncPunchBatchResultItem,
} from './syncBatch'
import type { LocalAttendanceOp } from '../db/attendanceDb'

export { generateClientOpId } from './clientOpId'

// ─── Types ────────────────────────────────────────────────────────────────────

export type TimePunch = Database['api']['Views']['time_punches']['Row']
export type TimeEntry = Database['api']['Views']['time_entries']['Row']
export type Employee = Database['api']['Views']['employees']['Row']

export type RecordPunchType =
  | 'in'
  | 'out'
  | 'break_start'
  | 'break_end'
  | 'day_start'
  | 'day_end'
  | 'travel_start'
  | 'travel_end'

export interface RecordPunchParams {
  punch_type: RecordPunchType
  employee_id: string
  client_op_id: string
  occurred_at?: string
  geo?: { lat: number; lng: number; accuracy: number; altitude?: number | null; speed?: number | null } | null
  location_permission?: 'granted' | 'denied' | 'timeout' | 'error' | 'notrequired'
  notes?: string | null
  source?: string
  pause_type?: string | null
  pause_counts_as_work?: boolean | null
  is_remote?: boolean
  geo_consent?: boolean
  geo_error?: string | null
  device_info?: Record<string, string> | null
}

export interface RecordPunchResult {
  success: boolean
  /** 'created' | 'duplicate' | 'error' */
  status: string
  punch_id?: string
  anomaly_codes?: string[]
  error?: string
}

// ─── Employee ─────────────────────────────────────────────────────────────────

/** Retorna l'empleat actiu associat a l'usuari autenticat en el tenant actiu. */
export async function getMyEmployee(userId: string, tenantId: string): Promise<Employee | null> {
  const { data, error } = await supabase
    .from('employees')
    .select('*')
    .eq('user_id', userId)
    .eq('tenant_id', tenantId)
    .eq('status', 'active')
    .maybeSingle()

  if (error) throw new Error(error.message)
  return data ?? null
}

// ─── Punch ────────────────────────────────────────────────────────────────────

/** Crida l'RPC `record_time_punch` i retorna el resultat normalitzat. */
export async function recordTimePunch(params: RecordPunchParams): Promise<RecordPunchResult> {
  const geoPayload = params.geo
    ? {
        lat: params.geo.lat,
        lng: params.geo.lng,
        latitude: params.geo.lat,
        longitude: params.geo.lng,
        accuracy: params.geo.accuracy,
        accuracy_m: params.geo.accuracy,
        accuracy_meters: params.geo.accuracy,
        altitude: params.geo.altitude,
        speed: params.geo.speed,
      }
    : undefined

  const { data, error } = await supabase.rpc('record_time_punch', {
    p_punch_type: params.punch_type,
    p_employee_id: params.employee_id,
    p_client_op_id: params.client_op_id,
    p_occurred_at: params.occurred_at ?? new Date().toISOString(),
    p_geo: geoPayload ?? undefined,
    p_location_perm: params.location_permission ?? 'notrequired',
    p_notes: params.notes ?? undefined,
    p_source: params.source ?? 'web',
    p_pause_type: params.pause_type ?? undefined,
    p_pause_counts_as_work: params.pause_counts_as_work ?? undefined,
    p_is_remote: params.is_remote ?? false,
    p_geo_consent: params.geo_consent ?? false,
    p_geo_error: params.geo_error ?? undefined,
    p_device_info: params.device_info ?? undefined,
  })

  if (error) {
    return { success: false, status: 'error', error: error.message }
  }

  const result = data as { status: string; punch_id?: string; anomaly_codes?: string[] }
  return {
    success: result.status === 'created' || result.status === 'duplicate',
    status: result.status,
    punch_id: result.punch_id,
    anomaly_codes: result.anomaly_codes,
  }
}

/** Lot offline via `api.sync_time_punches` (doc 15 / EX-05.1). */
export async function syncTimePunches(
  ops: LocalAttendanceOp[],
): Promise<SyncPunchBatchResultItem[]> {
  const batch: SyncPunchBatchItem[] = ops.map(buildSyncPunchBatchItem)
  const { data, error } = await supabase.rpc('sync_time_punches', {
    p_batch: batch,
  })

  if (error) {
    throw new Error(error.message)
  }

  if (!Array.isArray(data)) {
    throw new Error('sync_time_punches_invalid_response')
  }

  return data as SyncPunchBatchResultItem[]
}

// ─── Queries ──────────────────────────────────────────────────────────────────

/** Retorna tots els fitxatges d'avui per a un empleat. */
export async function getTodayPunches(employeeId: string): Promise<TimePunch[]> {
  const todayStart = new Date()
  todayStart.setHours(0, 0, 0, 0)
  const todayEnd = new Date()
  todayEnd.setHours(23, 59, 59, 999)

  const { data, error } = await supabase
    .from('time_punches')
    .select('*')
    .eq('employee_id', employeeId)
    .gte('occurred_at', todayStart.toISOString())
    .lte('occurred_at', todayEnd.toISOString())
    .order('occurred_at', { ascending: true })

  if (error) throw new Error(error.message)
  return data ?? []
}

/** Retorna les entrades (time_entries) d'avui per a un empleat. */
export async function getTodayEntries(employeeId: string): Promise<TimeEntry[]> {
  const d = new Date()
  const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

  const { data, error } = await supabase
    .from('time_entries')
    .select('*')
    .eq('employee_id', employeeId)
    .eq('work_date', today)
    .order('starts_at', { ascending: true })

  if (error) throw new Error(error.message)
  return data ?? []
}

/** Retorna fitxatges per a un rang de dates (historial personal). */
export async function getMyPunches(
  employeeId: string,
  from: string,
  to: string,
): Promise<TimePunch[]> {
  const { data, error } = await supabase
    .from('time_punches')
    .select('*')
    .eq('employee_id', employeeId)
    .gte('occurred_at', `${from}T00:00:00`)
    .lte('occurred_at', `${to}T23:59:59`)
    .order('occurred_at', { ascending: true })

  if (error) throw new Error(error.message)
  return data ?? []
}

/** Retorna entrades (time_entries) per a un rang de dates. */
export async function getMyEntries(
  employeeId: string,
  from: string,
  to: string,
): Promise<TimeEntry[]> {
  const { data, error } = await supabase
    .from('time_entries')
    .select('*')
    .eq('employee_id', employeeId)
    .gte('work_date', from)
    .lte('work_date', to)
    .order('work_date', { ascending: true })

  if (error) throw new Error(error.message)
  return data ?? []
}

// ─── Manager corrections ──────────────────────────────────────────────────────

export interface ManagerResolveOpenPauseParams {
  employee_id: string
  reason: string
  work_date?: string
  break_end_at?: string
  also_punch_out?: boolean
}

export interface ManagerResolveOpenPauseResult {
  success: boolean
  break_end_id?: string
  out_id?: string | null
  work_date?: string
  error?: string
}

/** Tanca una pausa oberta en nom d'un empleat (requereix attendance.adjust). */
export async function managerResolveOpenPause(
  params: ManagerResolveOpenPauseParams,
): Promise<ManagerResolveOpenPauseResult> {
  const { data, error } = await supabase.rpc('manager_resolve_open_pause' as never, {
    p_employee_id: params.employee_id,
    p_reason: params.reason,
    p_work_date: params.work_date ?? undefined,
    p_break_end_at: params.break_end_at ?? new Date().toISOString(),
    p_also_punch_out: params.also_punch_out ?? false,
  } as never)

  if (error) {
    return { success: false, error: error.message }
  }

  const result = data as {
    status: string
    break_end_id?: string
    out_id?: string | null
    work_date?: string
  }

  return {
    success: result.status === 'resolved',
    break_end_id: result.break_end_id,
    out_id: result.out_id,
    work_date: result.work_date,
  }
}

export interface AdjustTimeEntryParams {
  employee_id: string
  work_date: string
  adjusted_net_min: number
  break_minutes?: number
  reason: string
}

export interface AdjustTimeEntryResult {
  success: boolean
  entry_id?: string
  error?: string
}

/** Ajusta time_entry processada sense alterar raw punches (requereix attendance.adjust). */
export async function adjustTimeEntry(
  params: AdjustTimeEntryParams,
): Promise<AdjustTimeEntryResult> {
  const { data, error } = await supabase.rpc('adjust_time_entry', {
    p_employee_id: params.employee_id,
    p_work_date: params.work_date,
    p_adjusted_net_min: params.adjusted_net_min,
    p_break_minutes: params.break_minutes ?? undefined,
    p_reason: params.reason,
  })

  if (error) {
    return { success: false, error: error.message }
  }

  const result = data as { entry_id?: string; status?: string }
  return {
    success: result.status === 'adjusted',
    entry_id: result.entry_id,
  }
}

import { supabase } from '@/lib/supabase'

export interface StationFleetHealthStation {
  device_id: string
  name: string | null
  site_id: string | null
  status?: string | null
  location_path: string | null
  last_seen_at?: string | null
  connectivity_status: string
  outbox_pending_count?: number
  outbox_quarantined_count?: number
  ops_lockdown?: boolean
  config_version?: number
  reason?: string
}

export interface StationFleetHealth {
  tenant_id: string
  station_counts: Record<string, number>
  status_counts: Record<string, number>
  outbox: {
    stations_with_pending: number
    stations_with_quarantine: number
    pending_total: number
    quarantined_total: number
    lockdown_count: number
  }
  offline_stations: StationFleetHealthStation[]
  attention_stations: StationFleetHealthStation[]
  checked_at: string
}

export async function getStationFleetHealth(tenantId?: string | null): Promise<StationFleetHealth> {
  const { data, error } = await supabase.rpc('get_attendance_station_fleet_health', {
    p_tenant_id: tenantId ?? undefined,
  })
  if (error) throw error
  const payload = (data ?? {}) as Record<string, unknown>
  const outbox = (payload.outbox ?? {}) as Record<string, unknown>
  return {
    tenant_id: String(payload.tenant_id ?? ''),
    station_counts: (payload.station_counts ?? {}) as Record<string, number>,
    status_counts: (payload.status_counts ?? {}) as Record<string, number>,
    outbox: {
      stations_with_pending: Number(outbox.stations_with_pending ?? 0),
      stations_with_quarantine: Number(outbox.stations_with_quarantine ?? 0),
      pending_total: Number(outbox.pending_total ?? 0),
      quarantined_total: Number(outbox.quarantined_total ?? 0),
      lockdown_count: Number(outbox.lockdown_count ?? 0),
    },
    offline_stations: (payload.offline_stations ?? []) as StationFleetHealthStation[],
    attention_stations: (payload.attention_stations ?? []) as StationFleetHealthStation[],
    checked_at: String(payload.checked_at ?? new Date().toISOString()),
  }
}

export async function bulkUpdateAttendanceStationOps(input: {
  deviceIds: string[]
  status?: string | null
  opsLockdown?: boolean | null
  bumpConfigVersion?: boolean
}) {
  const { data, error } = await supabase.rpc('bulk_update_attendance_station_ops', {
    p_device_ids: input.deviceIds,
    p_status: input.status ?? undefined,
    p_ops_lockdown: input.opsLockdown ?? undefined,
    p_bump_config_version: input.bumpConfigVersion ?? true,
  })
  if (error) throw error
  return data as { ok: boolean; updated: number }
}

export async function bulkRevokeAttendanceStationSecrets(deviceIds: string[]) {
  const { data, error } = await supabase.rpc('bulk_revoke_attendance_station_secrets', {
    p_device_ids: deviceIds,
  })
  if (error) throw error
  return data as { ok: boolean; revoked: number }
}

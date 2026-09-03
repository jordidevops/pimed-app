import { supabase } from '@/lib/supabase'

export interface StationAdminAuditChange {
  field: string
  old: unknown
  new: unknown
  old_location_path?: string | null
  new_location_path?: string | null
}

export interface StationAdminAuditLogRow {
  id: string
  action: string
  created_at: string
  user_id: string | null
  user_name: string | null
  payload: {
    device_id?: string
    name?: string
    changes?: StationAdminAuditChange[]
    pairing_code_id?: string
    device_public_id?: string
    location_path?: string | null
    previous_status?: string
    new_status?: string
    [key: string]: unknown
  } | null
}

export async function listStationAdminAuditLogs(
  deviceId: string,
  limit = 100,
): Promise<StationAdminAuditLogRow[]> {
  const { data, error } = await supabase.rpc('list_attendance_station_admin_audit_logs', {
    p_device_id: deviceId,
    p_limit: limit,
  })
  if (error) throw error
  return (data ?? []) as StationAdminAuditLogRow[]
}

const ACTION_LABELS_CA: Record<string, string> = {
  ATTENDANCE_STATION_PAIRING_CODE_CREATED: 'Codi d\'aparellament generat',
  ATTENDANCE_STATION_REGISTERED: 'Estació registrada',
  ATTENDANCE_STATION_UPDATED: 'Estació actualitzada',
  ATTENDANCE_STATION_SECRET_REVOKED: 'Secret revocat',
}

export function stationAdminAuditActionLabel(action: string): string {
  return ACTION_LABELS_CA[action] ?? action
}

const FIELD_LABELS_CA: Record<string, string> = {
  name: 'Nom',
  site_id: 'Centre',
  location_id: 'Ubicació',
  status: 'Estat',
  allowed_methods: 'Mètodes',
  geo_antifraud_enabled: 'Validació geo',
  geo_antifraud_radius_m: 'Radi geo (m)',
  warn_wrong_scheduled_location: 'Avís ubicació planificada',
  block_wrong_scheduled_location: 'Bloqueig ubicació planificada',
  allow_unassigned_punch: 'Permetre sense assignació',
  warn_unassigned_punch: 'Avís sense assignació',
}

function formatValue(field: string, value: unknown): string {
  if (value == null || value === '') return '—'
  if (field === 'allowed_methods' && Array.isArray(value)) {
    return value.join(', ')
  }
  if (field === 'geo_antifraud_enabled') {
    return value === true || value === 'true' ? 'Sí' : 'No'
  }
  if (
    field === 'warn_wrong_scheduled_location'
    || field === 'block_wrong_scheduled_location'
    || field === 'allow_unassigned_punch'
    || field === 'warn_unassigned_punch'
  ) {
    return value === true || value === 'true' ? 'Sí' : 'No'
  }
  if (field === 'status') {
    const labels: Record<string, string> = {
      pending: 'Pendent',
      active: 'Activa',
      suspended: 'Suspesa',
      retired: 'Baixa',
    }
    return labels[String(value)] ?? String(value)
  }
  return String(value)
}

export function summarizeStationAdminAuditPayload(
  action: string,
  payload: StationAdminAuditLogRow['payload'],
): string {
  if (!payload) return '—'

  if (action === 'ATTENDANCE_STATION_PAIRING_CODE_CREATED') {
    const path = payload.location_path
    return path ? `Ubicació: ${path}` : 'Codi sense ubicació pre-assignada'
  }

  if (action === 'ATTENDANCE_STATION_REGISTERED') {
    const parts = [payload.name, payload.location_path].filter(Boolean)
    return parts.length > 0 ? parts.join(' · ') : (payload.device_public_id ?? '—')
  }

  if (action === 'ATTENDANCE_STATION_SECRET_REVOKED') {
    return payload.name ? String(payload.name) : 'Secret revocat'
  }

  if (action === 'ATTENDANCE_STATION_UPDATED') {
    const changes = payload.changes ?? []
    if (changes.length === 0) return payload.name ? String(payload.name) : 'Canvis aplicats'
    return changes
      .map((change) => {
        const label = FIELD_LABELS_CA[change.field] ?? change.field
        if (change.field === 'location_id') {
          const oldPath = change.old_location_path ?? change.old
          const newPath = change.new_location_path ?? change.new
          return `${label}: ${formatValue('location_id', oldPath)} → ${formatValue('location_id', newPath)}`
        }
        return `${label}: ${formatValue(change.field, change.old)} → ${formatValue(change.field, change.new)}`
      })
      .join('; ')
  }

  return payload.name ? String(payload.name) : '—'
}

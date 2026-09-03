import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type AttendanceStationRow = Database['api']['Views']['attendance_devices']['Row'] & {
  location_path?: string | null
  allowed_methods?: string[] | null
  geo_antifraud_enabled?: boolean | null
  geo_antifraud_radius_m?: number | null
  display_title?: string | null
  display_logo_url?: string | null
  effective_display_title?: string | null
  connectivity_status?: string | null
  entry_mode?: string | null
  employee_list_layout?: string | null
  document_match?: string | null
  document_suffix_length?: number | null
  identity_confirm?: string | null
  qr_identity_confirm?: string | null
  session_idle_seconds?: number | null
  session_return_countdown_seconds?: number | null
  session_allow_history?: boolean | null
  session_history_max_days?: number | null
  ux_preset?: string | null
  waiting_idle_seconds?: number | null
  mask_names_on_waiting?: boolean | null
  warn_wrong_scheduled_location?: boolean | null
  block_wrong_scheduled_location?: boolean | null
  allow_unassigned_punch?: boolean | null
  warn_unassigned_punch?: boolean | null
  outbox_pending_count?: number | null
  outbox_quarantined_count?: number | null
  outbox_reported_at?: string | null
  config_version?: number | null
  ops_lockdown?: boolean | null
}

export async function listAttendanceStations(): Promise<AttendanceStationRow[]> {
  const { data, error } = await supabase
    .from('attendance_devices')
    .select('*')
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as AttendanceStationRow[]
}

export async function createStationPairingCode(input: {
  siteId?: string | null
  locationId?: string | null
  ttlMinutes?: number
}) {
  const { data, error } = await supabase.rpc('create_attendance_station_pairing_code', {
    p_site_id: input.siteId ?? undefined,
    p_location_id: input.locationId ?? undefined,
    p_ttl_minutes: input.ttlMinutes ?? 15,
  })
  if (error) throw error
  return data as {
    pairing_code_id: string
    code: string
    expires_at: string
    site_id: string | null
    location_id: string | null
  }
}

export async function updateAttendanceStation(input: {
  deviceId: string
  name?: string
  siteId?: string | null
  locationId?: string | null
  status?: string
  allowedMethods?: string[]
  geoAntifraudEnabled?: boolean
  geoAntifraudRadiusM?: number
  displayTitle?: string
  displayLogoUrl?: string
  entryMode?: string
  employeeListLayout?: string
  documentMatch?: string
  documentSuffixLength?: number
  identityConfirm?: string
  qrIdentityConfirm?: string
  sessionIdleSeconds?: number
  sessionReturnCountdownSeconds?: number
  sessionAllowHistory?: boolean
  sessionHistoryMaxDays?: number
  uxPreset?: string
  waitingIdleSeconds?: number
  maskNamesOnWaiting?: boolean
  warnWrongScheduledLocation?: boolean
  blockWrongScheduledLocation?: boolean
  allowUnassignedPunch?: boolean
  warnUnassignedPunch?: boolean
}) {
  const { data, error } = await supabase.rpc('update_attendance_station', {
    p_device_id: input.deviceId,
    p_name: input.name ?? undefined,
    p_site_id: input.siteId ?? undefined,
    p_location_id: input.locationId ?? undefined,
    p_status: input.status ?? undefined,
    p_allowed_methods: input.allowedMethods ?? undefined,
    p_geo_antifraud_enabled: input.geoAntifraudEnabled ?? undefined,
    p_geo_antifraud_radius_m: input.geoAntifraudRadiusM ?? undefined,
    p_display_title: input.displayTitle ?? undefined,
    p_display_logo_url: input.displayLogoUrl ?? undefined,
    p_entry_mode: input.entryMode ?? undefined,
    p_employee_list_layout: input.employeeListLayout ?? undefined,
    p_document_match: input.documentMatch ?? undefined,
    p_document_suffix_length: input.documentSuffixLength ?? undefined,
    p_identity_confirm: input.identityConfirm ?? undefined,
    p_qr_identity_confirm: input.qrIdentityConfirm ?? undefined,
    p_session_idle_seconds: input.sessionIdleSeconds ?? undefined,
    p_session_return_countdown_seconds: input.sessionReturnCountdownSeconds ?? undefined,
    p_session_allow_history: input.sessionAllowHistory ?? undefined,
    p_session_history_max_days: input.sessionHistoryMaxDays ?? undefined,
    p_ux_preset: input.uxPreset ?? undefined,
    p_waiting_idle_seconds: input.waitingIdleSeconds ?? undefined,
    p_mask_names_on_waiting: input.maskNamesOnWaiting ?? undefined,
    p_warn_wrong_scheduled_location: input.warnWrongScheduledLocation ?? undefined,
    p_block_wrong_scheduled_location: input.blockWrongScheduledLocation ?? undefined,
    p_allow_unassigned_punch: input.allowUnassignedPunch ?? undefined,
    p_warn_unassigned_punch: input.warnUnassignedPunch ?? undefined,
  })
  if (error) throw error
  return data as Record<string, unknown>
}

export async function revokeAttendanceStationSecret(deviceId: string) {
  const { data, error } = await supabase.rpc('revoke_attendance_station_secret', {
    p_device_id: deviceId,
  })
  if (error) throw error
  return data as Record<string, unknown>
}

import { createAdminClient } from "../supabase.ts";

export interface StationContext {
  device_id: string;
  tenant_id: string;
  site_id: string | null;
  location_id: string | null;
  location_path: string | null;
  name: string;
  display_title: string | null;
  display_logo_url: string | null;
  effective_display_title: string;
  status: string;
  type: string;
  allowed_methods: string[] | null;
  geo_antifraud_enabled: boolean;
  geo_antifraud_radius_m: number;
  location_has_geo: boolean;
  site_timezone?: string;
  last_seen_at?: string | null;
  connectivity_status?: string | null;
  seconds_since_seen?: number | null;
  entry_mode?: "employee_list" | "document_entry";
  employee_list_layout?: "compact" | "two_column" | "search_first";
  document_match?: "exact" | "suffix";
  document_suffix_length?: number;
  identity_confirm?: "none" | "tap_name" | "portal_pin";
  qr_identity_confirm?: "none" | "tap_name" | "portal_pin";
  session_idle_seconds?: number;
  session_return_countdown_seconds?: number;
  session_allow_history?: boolean;
  session_history_max_days?: number;
  ux_preset?: string;
  waiting_idle_seconds?: number;
  mask_names_on_waiting?: boolean;
  allow_unassigned_punch?: boolean;
  warn_unassigned_punch?: boolean;
  warn_wrong_scheduled_location?: boolean;
  block_wrong_scheduled_location?: boolean;
  outbox_pending_count?: number;
  outbox_quarantined_count?: number;
  config_version?: number;
  ops_lockdown?: boolean;
}

export async function verifyStationCredentials(
  devicePublicId: string,
  deviceSecret: string,
): Promise<StationContext> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("verify_attendance_station_credentials", {
    p_device_public_id: devicePublicId,
    p_device_secret: deviceSecret,
  });
  if (error) {
    throw new Error(error.message);
  }
  return data as StationContext;
}

/** EX-05.6 FF-04: deferred offline punch delivery. */
export async function isStationOfflineDeferredEnabled(tenantId: string): Promise<boolean> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("is_tenant_feature_enabled", {
    p_tenant_id: tenantId,
    p_feature_key: "station_offline_deferred_punch",
  });
  if (error) throw new Error(error.message);
  return Boolean(data);
}

export async function recordStationHeartbeat(
  devicePublicId: string,
  deviceSecret: string,
  telemetry?: { pendingCount?: number; quarantinedCount?: number },
): Promise<{
  device_id: string;
  last_seen_at: string;
  connectivity_status: string;
  seconds_since_seen: number;
  outbox_pending_count?: number;
  outbox_quarantined_count?: number;
  config_version?: number;
  ops_lockdown?: boolean;
}> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("record_attendance_station_heartbeat", {
    p_device_public_id: devicePublicId,
    p_device_secret: deviceSecret,
    p_pending_count: telemetry?.pendingCount ?? undefined,
    p_quarantined_count: telemetry?.quarantinedCount ?? undefined,
  });
  if (error) throw new Error(error.message);
  return data as {
    device_id: string;
    last_seen_at: string;
    connectivity_status: string;
    seconds_since_seen: number;
    outbox_pending_count?: number;
    outbox_quarantined_count?: number;
    config_version?: number;
    ops_lockdown?: boolean;
  };
}

export async function registerStationDevice(input: {
  pairing_code: string;
  device_public_id: string;
  device_secret: string;
  local_pin: string;
  name?: string;
}) {
  const db = createAdminClient();
  const { data, error } = await db.rpc("register_attendance_device", {
    p_pairing_code: input.pairing_code,
    p_device_public_id: input.device_public_id,
    p_device_secret: input.device_secret,
    p_local_pin: input.local_pin,
    p_name: input.name ?? null,
    p_metadata: {},
  });
  if (error) throw new Error(error.message);
  return data as Record<string, unknown>;
}

export async function listStationEmployees(deviceId: string) {
  const db = createAdminClient();
  const { data, error } = await db.rpc("list_attendance_station_employees", {
    p_device_id: deviceId,
  });
  if (error) throw new Error(error.message);
  return data as { employees: Array<Record<string, unknown>> };
}

export async function listStationPauseConfigs(deviceId: string) {
  const db = createAdminClient();
  const { data, error } = await db.rpc("list_attendance_station_pause_configs", {
    p_device_id: deviceId,
  });
  if (error) throw new Error(error.message);
  return data as {
    configs: Array<{
      id: string;
      key: string;
      label_i18n: Record<string, string> | null;
      counts_as_work: boolean;
      max_duration_minutes: number | null;
      sort_order: number;
    }>;
  };
}

export async function getStationEmployeeLocationHint(deviceId: string, employeeId: string) {
  const db = createAdminClient();
  const { data, error } = await db.rpc("station_employee_location_hint", {
    p_device_id: deviceId,
    p_employee_id: employeeId,
  });
  if (error) throw new Error(error.message);
  return data as {
    employee_id: string;
    work_date: string;
    station_location_id: string | null;
    station_location_name: string | null;
    scheduled_location_id: string | null;
    scheduled_location_name: string | null;
    scheduled_location_path: string | null;
    scheduled_location_ids: string[];
    wrong_scheduled_location: boolean;
    warn_wrong_scheduled_location: boolean;
    block_wrong_scheduled_location: boolean;
    outside_assignment?: boolean;
    allow_unassigned_punch?: boolean;
    warn_unassigned_punch?: boolean;
    assignment_scope_active?: boolean;
  };
}

export type StationDocumentResolveMatch = {
  employee_id: string;
  full_name: string;
  day_state?: string | null;
  next_punch?: "in" | "out" | null;
};

export type StationDocumentResolveResult = {
  status: "matched" | "ambiguous" | "not_found";
  matches: StationDocumentResolveMatch[];
  employee_id?: string;
  full_name?: string;
  day_state?: string | null;
  next_punch?: "in" | "out" | null;
  document_match?: string;
  document_suffix_length?: number;
  pin_required?: boolean;
};

export async function resolveStationEmployeeDocument(
  deviceId: string,
  documentId: string,
): Promise<StationDocumentResolveResult> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("resolve_attendance_station_employee_document", {
    p_device_id: deviceId,
    p_document_id: documentId,
  });
  if (error) throw new Error(error.message);
  return data as StationDocumentResolveResult;
}

export async function recordStationPunch(input: {
  device_id: string;
  employee_id: string;
  client_op_id: string;
  punch_type: string;
  pause_type?: string | null;
  source?: "station" | "qr";
  device_geo?: Record<string, unknown> | null;
  identity_token?: string | null;
  /** Offline sync: instant del toc. Online: ometre (servidor usa now()). */
  occurred_at?: string | null;
}) {
  const db = createAdminClient();
  const { data, error } = await db.rpc("record_station_time_punch", {
    p_device_id: input.device_id,
    p_employee_id: input.employee_id,
    p_client_op_id: input.client_op_id,
    p_punch_type: input.punch_type,
    p_pause_type: input.pause_type ?? null,
    p_source: input.source ?? "station",
    p_device_geo: input.device_geo ?? null,
    p_identity_token: input.identity_token ?? null,
    p_occurred_at: input.occurred_at ?? null,
  });
  if (error) throw new Error(error.message);
  return data as Record<string, unknown>;
}

export interface StationPinVerifyResult {
  status: "ok" | "invalid" | "invalid_format" | "locked" | "no_pin" | string;
  pin_attempts?: number;
  retry_after_seconds?: number;
}

export async function verifyStationLocalPin(
  deviceId: string,
  localPin: string,
): Promise<StationPinVerifyResult> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("verify_attendance_station_local_pin", {
    p_device_id: deviceId,
    p_local_pin: localPin,
  });
  if (error) throw new Error(error.message);
  return data as StationPinVerifyResult;
}

export async function verifyStationEmployeePin(
  deviceId: string,
  employeeId: string,
  pin: string,
): Promise<StationPinVerifyResult> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("verify_attendance_station_employee_pin", {
    p_device_id: deviceId,
    p_employee_id: employeeId,
    p_pin: pin,
  });
  if (error) throw new Error(error.message);
  return data as StationPinVerifyResult;
}

export type StationEmployeeHistoryPayload = {
  employee_id: string;
  full_name: string | null;
  from: string;
  to: string;
  max_days: number;
  site_timezone: string;
  entries: Array<{
    id: string;
    work_date: string;
    starts_at: string | null;
    ends_at: string | null;
    net_minutes: number | null;
    status: string;
  }>;
  punches: Array<{
    id: string;
    punch_type: string;
    occurred_at: string;
    source: string | null;
  }>;
};

export async function getStationEmployeeHistory(
  deviceId: string,
  employeeId: string,
  from: string,
  to: string,
): Promise<StationEmployeeHistoryPayload> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("get_attendance_station_employee_history", {
    p_device_id: deviceId,
    p_employee_id: employeeId,
    p_from: from,
    p_to: to,
  });
  if (error) throw new Error(error.message);
  return data as StationEmployeeHistoryPayload;
}

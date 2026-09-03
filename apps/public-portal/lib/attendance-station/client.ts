import {
  LEGACY_STATION_STORAGE_KEY,
  STATION_META_STORAGE_KEY,
} from "./constants";

export interface StationMeta {
  device_id: string;
  device_public_id: string;
}

export function readStationMeta(): StationMeta | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = sessionStorage.getItem(STATION_META_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as StationMeta;
    if (!parsed.device_public_id || !parsed.device_id) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function writeStationMeta(meta: StationMeta): void {
  sessionStorage.setItem(STATION_META_STORAGE_KEY, JSON.stringify(meta));
}

export function clearStationMeta(): void {
  sessionStorage.removeItem(STATION_META_STORAGE_KEY);
}

/** @deprecated Use readStationMeta — kept for gradual migration in UI code. */
export function readStationCredentials(): StationMeta | null {
  return readStationMeta();
}

/** @deprecated Secrets are stored in HttpOnly cookies via the API proxy. */
export function writeStationCredentials(meta: StationMeta): void {
  writeStationMeta(meta);
}

export async function clearStationCredentials(): Promise<void> {
  clearStationMeta();
  try {
    await fetch("/api/station/session/logout", {
      method: "POST",
      credentials: "include",
    });
  } catch {
    // Best-effort cookie clear; sessionStorage already cleared.
  }
  if (typeof window !== "undefined") {
    localStorage.removeItem(LEGACY_STATION_STORAGE_KEY);
  }
}

export async function migrateLegacyStationCredentials(): Promise<boolean> {
  if (typeof window === "undefined") return false;
  const raw = localStorage.getItem(LEGACY_STATION_STORAGE_KEY);
  if (!raw) return false;

  try {
    const legacy = JSON.parse(raw) as {
      device_id?: string;
      device_public_id?: string;
      device_secret?: string;
    };
    if (!legacy.device_public_id || !legacy.device_secret || !legacy.device_id) {
      localStorage.removeItem(LEGACY_STATION_STORAGE_KEY);
      return false;
    }

    const res = await fetch("/api/station/session/migrate", {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        device_id: legacy.device_id,
        device_public_id: legacy.device_public_id,
        device_secret: legacy.device_secret,
      }),
    });

    if (!res.ok) return false;

    const payload = await res.json() as {
      device_id: string;
      device_public_id: string;
    };
    writeStationMeta({
      device_id: payload.device_id,
      device_public_id: payload.device_public_id,
    });
    localStorage.removeItem(LEGACY_STATION_STORAGE_KEY);
    return true;
  } catch {
    return false;
  }
}

async function callStationApi<T>(
  route: string,
  options: {
    method?: "GET" | "POST";
    body?: unknown;
  } = {},
): Promise<T> {
  const res = await fetch(`/api/station/${route.replace(/^\//, "")}`, {
    method: options.method ?? "GET",
    credentials: "include",
    headers: {
      "Content-Type": "application/json",
    },
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
    cache: "no-store",
  });

  const payload = await res.json().catch(() => ({}));
  if (!res.ok) {
    const errBody = payload as {
      error?: {
        message?: string;
        code?: string;
        retry_after_seconds?: number;
      };
    };
    const code = errBody.error?.code ?? errBody.error?.message ?? "station_request_failed";
    const err = new Error(code) as Error & { retryAfterSeconds?: number };
    if (errBody.error?.retry_after_seconds != null) {
      err.retryAfterSeconds = errBody.error.retry_after_seconds;
    }
    throw err;
  }
  return payload as T;
}

export async function registerStation(input: {
  pairing_code: string;
  local_pin: string;
  name?: string;
}) {
  const result = await callStationApi<{
    device_id: string;
    device_public_id: string;
    status: string;
  }>("register", { method: "POST", body: input });

  writeStationMeta({
    device_id: result.device_id,
    device_public_id: result.device_public_id,
  });

  return result;
}

export type StationEntryMode = "employee_list" | "document_entry";
export type StationListLayout = "compact" | "two_column" | "search_first";
export type StationIdentityConfirm = "none" | "tap_name" | "portal_pin";

export async function fetchStationBootstrap() {
  return callStationApi<{
    device_id: string;
    device_public_id?: string | null;
    name: string;
    display_title?: string | null;
    display_logo_url?: string | null;
    effective_display_title?: string;
    status: string;
    location_id: string | null;
    location_path: string | null;
    ready: boolean;
    allowed_methods?: string[];
    geo_antifraud_enabled?: boolean;
    geo_antifraud_radius_m?: number;
    location_has_geo?: boolean;
    last_seen_at?: string | null;
    connectivity_status?: string | null;
    entry_mode?: StationEntryMode;
    employee_list_layout?: StationListLayout;
    document_match?: "exact" | "suffix";
    document_suffix_length?: number;
    identity_confirm?: StationIdentityConfirm;
    qr_identity_confirm?: StationIdentityConfirm;
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
    /** EX-05.6 FF-04: cua offline (deferred punch). */
    offline_deferred_punch_enabled?: boolean;
    ops_lockdown?: boolean;
    config_version?: number;
  }>("bootstrap");
}

export async function postStationHeartbeat(input?: {
  pendingCount?: number;
  quarantinedCount?: number;
}) {
  return callStationApi<{
    device_id: string;
    last_seen_at: string;
    connectivity_status: string;
    seconds_since_seen: number;
    outbox_pending_count?: number;
    outbox_quarantined_count?: number;
    config_version?: number;
    ops_lockdown?: boolean;
  }>("heartbeat", {
    method: "POST",
    body: {
      pending_count: input?.pendingCount ?? 0,
      quarantined_count: input?.quarantinedCount ?? 0,
    },
  });
}

export async function fetchStationEmployees() {
  return callStationApi<{
    employees: Array<{
      employee_id: string;
      full_name: string;
      last_punch_type: string | null;
      last_punch_at: string | null;
      day_state?: string | null;
      next_punch?: "in" | "out" | "break_end" | null;
      active_pause_type?: string | null;
      can_start_pause?: boolean;
      can_end_pause?: boolean;
    }>;
    location_path: string | null;
    assignment_mode?: "zone" | "site_fallback";
    scope_has_assignments?: boolean;
  }>("employees");
}

export type StationPauseConfig = {
  id: string;
  key: string;
  label_i18n: Record<string, string> | null;
  counts_as_work: boolean;
  max_duration_minutes: number | null;
  sort_order: number;
};

export async function fetchStationPauseConfigs() {
  return callStationApi<{ configs: StationPauseConfig[] }>("pause-configs");
}

export async function postStationPunch(input: {
  employee_id: string;
  punch_type: "in" | "out" | "break_start" | "break_end";
  pause_type?: string;
  source?: "station" | "qr";
  identity_token?: string;
  client_op_id?: string;
  /** Offline sync (EX-05.3): instant del toc. Online: ometre. */
  occurred_at?: string;
  device_geo?: {
    latitude: number;
    longitude: number;
    accuracy_meters?: number;
    timestamp: string;
  };
}) {
  return callStationApi<{
    punch_id: string;
    status: string;
    location_name?: string;
    occurred_at?: string;
    source?: string;
    scheduled_location_id?: string | null;
    scheduled_location_name?: string | null;
    scheduled_location_path?: string | null;
    wrong_scheduled_location?: boolean;
    outside_assignment?: boolean;
    punched_outside_assignment?: boolean;
    anomaly_codes?: string[];
  }>("punch", { method: "POST", body: input });
}

export async function fetchStationEmployeeLocationHint(employeeId: string) {
  return callStationApi<{
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
  }>("employee-location-hint", {
    method: "POST",
    body: { employee_id: employeeId },
  });
}

export async function resolveStationIdentityToken(token: string) {
  return callStationApi<{
    employee_id: string;
    full_name: string;
    method: string;
    day_state: string;
    next_punch: "in" | "out" | null;
    token_id: string;
  }>("resolve-identity", { method: "POST", body: { token } });
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

export async function resolveStationEmployeeDocument(documentId: string) {
  return callStationApi<StationDocumentResolveResult>("resolve-employee-document", {
    method: "POST",
    body: { document_id: documentId },
  });
}

export async function verifyStationLocalPin(localPin: string) {
  return callStationApi<{ status: string; retry_after_seconds?: number }>("verify-pin", {
    method: "POST",
    body: { local_pin: localPin },
  });
}

export async function verifyStationEmployeePin(employeeId: string, pin: string) {
  return callStationApi<{
    status: "ok" | "invalid" | "locked" | "invalid_format" | "no_pin" | "employee_not_allowed" | string;
    pin_attempts?: number;
    retry_after_seconds?: number;
  }>("verify-employee-pin", {
    method: "POST",
    body: { employee_id: employeeId, pin },
  });
}

export type StationHistoryDay = {
  id: string;
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  net_minutes: number | null;
  status: string;
};

export type StationHistoryPunch = {
  id: string;
  punch_type: string;
  occurred_at: string;
  source: string | null;
};

export async function fetchStationEmployeeHistory(input: {
  employeeId: string;
  from: string;
  to: string;
  pin: string;
}) {
  return callStationApi<{
    employee_id: string;
    full_name: string | null;
    from: string;
    to: string;
    max_days: number;
    site_timezone: string;
    entries: StationHistoryDay[];
    punches: StationHistoryPunch[];
  }>("employee-history", {
    method: "POST",
    body: {
      employee_id: input.employeeId,
      from: input.from,
      to: input.to,
      pin: input.pin,
    },
  });
}

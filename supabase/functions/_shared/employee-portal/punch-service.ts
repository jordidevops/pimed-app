import { createAdminClient } from "../supabase.ts";
import { sanitizeClientDeviceInfo } from "../device-info.ts";
import { recordAccessLog } from "./repository.ts";
import { hasPendingProtocol } from "./documents-service.ts";

export interface PortalPunchRow {
  id: string;
  punch_type: string;
  occurred_at: string;
  received_at: string | null;
  anomaly_codes: string[] | null;
  source: string | null;
  pause_type: string | null;
  is_remote: boolean | null;
}

export interface PortalTodayPayload {
  employee_id: string;
  tenant_id: string;
  work_date: string;
  punches: PortalPunchRow[];
  last_punch_type: string | null;
  last_punch_at: string | null;
  current_status: "outside" | "on_day" | "working" | "on_pause" | "traveling" | "unknown";
  active_pause_type: string | null;
  open_pause_since: string | null;
  work_profile?: string | null;
  legacy_in_out_only?: boolean | null;
  day_state?: string | null;
  punch_only_at_stations?: boolean | null;
}

export async function getPortalToday(
  employee_id: string,
  tenant_id: string,
): Promise<PortalTodayPayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_today", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });

  if (error) {
    throw new Error(`getPortalToday failed: ${error.message}`);
  }

  const payload = data as PortalTodayPayload;

  if (payload.work_profile == null) {
    const profile = await getPortalPunchProfile(employee_id, tenant_id);
    return { ...payload, ...profile };
  }

  return payload;
}

export interface PortalPunchProfile {
  work_profile: string;
  legacy_in_out_only: boolean;
}

export async function getPortalPunchProfile(
  employee_id: string,
  tenant_id: string,
): Promise<PortalPunchProfile> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_punch_profile", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });

  if (error) {
    throw new Error(`getPortalPunchProfile failed: ${error.message}`);
  }

  const row = data as { work_profile?: string; legacy_in_out_only?: boolean };
  return {
    work_profile: row.work_profile ?? "fixed_site",
    legacy_in_out_only: Boolean(row.legacy_in_out_only),
  };
}

export type PortalPunchType =
  | "in"
  | "out"
  | "break_start"
  | "break_end"
  | "day_start"
  | "day_end"
  | "travel_start"
  | "travel_end";

export interface RecordPortalPunchInput {
  employee_id: string;
  tenant_id: string;
  token_id: string;
  client_op_id: string;
  punch_type: PortalPunchType;
  occurred_at?: string;
  device_info?: Record<string, string> | null;
  pause_type?: string | null;
  pause_counts_as_work?: boolean | null;
}

export interface RecordPortalPunchResult {
  punch_id: string;
  status: string;
  anomaly_codes: string[];
}

export interface SyncPortalPunchOp {
  client_op_id: string;
  punch_type: PortalPunchType;
  occurred_at: string;
  device_info?: Record<string, string> | null;
  pause_type?: string | null;
  pause_counts_as_work?: boolean | null;
}

export interface SyncPortalPunchResultItem {
  client_op_id: string;
  status: string;
  punch_id?: string | null;
  message?: string | null;
}

function punchAccessAction(punchType: PortalPunchType): string {
  return punchType === "in"
    ? "punch_in"
    : punchType === "out"
    ? "punch_out"
    : punchType === "day_start"
    ? "day_start"
    : punchType === "day_end"
    ? "day_end"
    : punchType === "travel_start"
    ? "travel_start"
    : punchType === "travel_end"
    ? "travel_end"
    : punchType === "break_start"
    ? "pause_start"
    : "pause_end";
}

export async function recordPortalPunch(
  input: RecordPortalPunchInput,
): Promise<RecordPortalPunchResult> {
  const pendingProtocol = await hasPendingProtocol(input.employee_id, input.tenant_id);
  if (pendingProtocol) {
    throw new PunchError(
      "protocol_pending",
      403,
      "Pending attendance protocol acknowledgement",
    );
  }

  const db = createAdminClient();
  const occurredAt = input.occurred_at ?? new Date().toISOString();

  const { data, error } = await db.rpc("record_time_punch", {
    p_employee_id: input.employee_id,
    p_client_op_id: input.client_op_id,
    p_punch_type: input.punch_type,
    p_occurred_at: occurredAt,
    p_geo: null,
    p_location_perm: "notrequired",
    p_notes: null,
    p_source: "portal",
    p_device_id: null,
    p_pause_type: input.pause_type ?? null,
    p_pause_counts_as_work: input.pause_counts_as_work ?? null,
    p_is_remote: false,
    p_geo_consent: false,
    p_geo_error: null,
    p_device_info: sanitizeClientDeviceInfo(input.device_info, "employee_portal"),
  });

  if (error) {
    const message = error.message ?? "punch_failed";
    if (message.includes("invalid_sequence")) {
      throw new PunchError("invalid_sequence", 409, message);
    }
    if (message.includes("employee_not_active")) {
      throw new PunchError("employee_not_active", 403, message);
    }
    if (message.includes("punch_only_at_stations")) {
      throw new PunchError("punch_only_at_stations", 403, message);
    }
    throw new PunchError("punch_failed", 500, message);
  }

  const result = data as RecordPortalPunchResult;

  await recordAccessLog({
    token_id: input.token_id,
    employee_id: input.employee_id,
    tenant_id: input.tenant_id,
    action: punchAccessAction(input.punch_type),
    http_status: 200,
  }).catch(() => undefined);

  return result;
}

/**
 * EX-05.1: lot offline via `api.sync_time_punches`.
 * `employee_id` sempre ve de la sessió (no del client).
 */
export async function syncPortalPunches(input: {
  employee_id: string;
  tenant_id: string;
  token_id: string;
  ops: SyncPortalPunchOp[];
}): Promise<SyncPortalPunchResultItem[]> {
  if (input.ops.length === 0) return [];

  const pendingProtocol = await hasPendingProtocol(input.employee_id, input.tenant_id);
  if (pendingProtocol) {
    throw new PunchError(
      "protocol_pending",
      403,
      "Pending attendance protocol acknowledgement",
    );
  }

  const batch = input.ops.map((op) => ({
    id: op.client_op_id,
    kind: "punch",
    payload: {
      employee_id: input.employee_id,
      punch_type: op.punch_type,
      occurred_at: op.occurred_at,
      source: "portal",
      pause_type: op.pause_type ?? null,
      pause_counts_as_work: op.pause_counts_as_work ?? null,
      is_remote: false,
      geo_consent: false,
      device_info: sanitizeClientDeviceInfo(op.device_info, "employee_portal"),
    },
  }));

  const db = createAdminClient();
  const { data, error } = await db.rpc("sync_time_punches", {
    p_batch: batch,
  });

  if (error) {
    throw new PunchError("punch_sync_failed", 500, error.message ?? "punch_sync_failed");
  }

  const raw = (Array.isArray(data) ? data : []) as Array<{
    client_op_id?: string;
    status?: string;
    server_id?: string | null;
    message?: string | null;
  }>;

  const results: SyncPortalPunchResultItem[] = raw.map((row) => ({
    client_op_id: row.client_op_id ?? "",
    status: row.status ?? "rejected",
    punch_id: row.server_id ?? null,
    message: row.message ?? null,
  }));

  const byId = new Map(input.ops.map((op) => [op.client_op_id, op]));
  for (const result of results) {
    if (result.status !== "created" && result.status !== "duplicate") continue;
    const op = byId.get(result.client_op_id);
    if (!op) continue;
    await recordAccessLog({
      token_id: input.token_id,
      employee_id: input.employee_id,
      tenant_id: input.tenant_id,
      action: punchAccessAction(op.punch_type),
      http_status: 200,
    }).catch(() => undefined);
  }

  return results;
}

export class PunchError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "PunchError";
  }
}

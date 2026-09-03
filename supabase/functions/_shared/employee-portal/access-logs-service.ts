import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalAccessLogRow {
  id: number;
  accessed_at: string;
  action: string;
  http_status: number | null;
  failure_reason: string | null;
  ip_address: string | null;
  metadata?: Record<string, unknown> | null;
}

export interface PortalPeriodConfirmationRow {
  id: string;
  period_from: string;
  period_to: string;
  cycle_type: string;
  calendar_year: number;
  calendar_month: number;
  confirmed_at: string;
  confirmed_via: string;
}

export interface PortalAccessLogsResponse {
  logs: PortalAccessLogRow[];
  period_confirmations: PortalPeriodConfirmationRow[];
}

export async function getPortalAccessLogs(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  limit = 50,
): Promise<PortalAccessLogsResponse> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_access_logs", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_token_id: token_id,
    p_limit: limit,
  });

  if (error) {
    throw new AccessLogsError("access_logs_failed", 500, error.message);
  }

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_access_logs",
    http_status: 200,
  }).catch(() => undefined);

  const payload = (data ?? {}) as Record<string, unknown>;
  const logsRaw = Array.isArray(payload.logs) ? payload.logs : Array.isArray(data) ? data : [];
  const confirmationsRaw = Array.isArray(payload.period_confirmations)
    ? payload.period_confirmations
    : [];

  return {
    logs: logsRaw as PortalAccessLogRow[],
    period_confirmations: confirmationsRaw.map((row) => {
      const r = row as Record<string, unknown>;
      return {
        id: String(r.id ?? ""),
        period_from: String(r.period_from ?? ""),
        period_to: String(r.period_to ?? ""),
        cycle_type: String(r.cycle_type ?? ""),
        calendar_year: Number(r.calendar_year ?? 0),
        calendar_month: Number(r.calendar_month ?? 0),
        confirmed_at: String(r.confirmed_at ?? ""),
        confirmed_via: String(r.confirmed_via ?? ""),
      };
    }),
  };
}

export class AccessLogsError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "AccessLogsError";
  }
}

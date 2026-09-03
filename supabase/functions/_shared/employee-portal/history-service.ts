import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalHistoryEntry {
  id: string;
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  net_minutes: number | null;
  status: string;
}

export interface PortalHistoryPunch {
  id: string;
  punch_type: string;
  occurred_at: string;
  source: string | null;
}

export interface PortalHistoryPayload {
  employee_id: string;
  tenant_id: string;
  from: string;
  to: string;
  days: PortalHistoryEntry[];
  total_net_minutes: number;
}

function mapEntry(raw: Record<string, unknown>): PortalHistoryEntry {
  return {
    id: String(raw.id ?? ""),
    work_date: String(raw.work_date ?? ""),
    starts_at: raw.starts_at != null ? String(raw.starts_at) : null,
    ends_at: raw.ends_at != null ? String(raw.ends_at) : null,
    net_minutes: raw.net_minutes != null ? Number(raw.net_minutes) : null,
    status: String(raw.status ?? "open"),
  };
}

function punchWorkDate(occurredAt: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Madrid" }).format(
    new Date(occurredAt),
  );
}

function buildRowsFromPunches(punches: PortalHistoryPunch[]): PortalHistoryEntry[] {
  const byDate = new Map<string, PortalHistoryPunch[]>();

  for (const punch of punches) {
    if (!punch.occurred_at) continue;
    const workDate = punchWorkDate(punch.occurred_at);
    const list = byDate.get(workDate) ?? [];
    list.push(punch);
    byDate.set(workDate, list);
  }

  const rows: PortalHistoryEntry[] = [];

  for (const [workDate, dayPunches] of byDate) {
    dayPunches.sort((a, b) => a.occurred_at.localeCompare(b.occurred_at));

    const firstIn = dayPunches.find((p) => p.punch_type === "in");
    const lastOut = [...dayPunches].reverse().find((p) => p.punch_type === "out");

    let netMinutes: number | null = null;
    if (firstIn?.occurred_at && lastOut?.occurred_at) {
      netMinutes = Math.max(
        0,
        Math.round(
          (new Date(lastOut.occurred_at).getTime() - new Date(firstIn.occurred_at).getTime()) /
            60_000,
        ),
      );
    }

    const status = lastOut ? "closed" : firstIn ? "open" : "missing";

    rows.push({
      id: `punch-summary-${workDate}`,
      work_date: workDate,
      starts_at: firstIn?.occurred_at ?? null,
      ends_at: lastOut?.occurred_at ?? null,
      net_minutes: netMinutes,
      status,
    });
  }

  return rows.sort((a, b) => b.work_date.localeCompare(a.work_date));
}

function mergeHistoryDays(
  entries: PortalHistoryEntry[],
  punches: PortalHistoryPunch[],
): PortalHistoryEntry[] {
  if (entries.length > 0) {
    const entryDates = new Set(entries.map((e) => e.work_date));
    const punchOnly = buildRowsFromPunches(
      punches.filter((p) => !entryDates.has(punchWorkDate(p.occurred_at))),
    );
    return [...entries, ...punchOnly].sort((a, b) => b.work_date.localeCompare(a.work_date));
  }
  return buildRowsFromPunches(punches);
}

export async function getPortalHistory(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  from: string,
  to: string,
): Promise<PortalHistoryPayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_history", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_from: from,
    p_to: to,
  });

  if (error) {
    const message = error.message ?? "history_failed";
    if (message.includes("employee_not_found")) {
      throw new HistoryError("employee_not_found", 404, message);
    }
    if (message.includes("invalid_date_range") || message.includes("date_range_too_large")) {
      throw new HistoryError("invalid_date_range", 400, message);
    }
    throw new HistoryError("history_failed", 500, message);
  }

  const payload = data as Record<string, unknown>;
  const entriesRaw = Array.isArray(payload.entries) ? payload.entries : [];
  const punchesRaw = Array.isArray(payload.punches) ? payload.punches : [];

  const entries = entriesRaw.map((e) => mapEntry(e as Record<string, unknown>));
  const punches = punchesRaw.map((p) => {
    const row = p as Record<string, unknown>;
    return {
      id: String(row.id ?? ""),
      punch_type: String(row.punch_type ?? ""),
      occurred_at: String(row.occurred_at ?? ""),
      source: row.source != null ? String(row.source) : null,
    };
  });

  const days = mergeHistoryDays(entries, punches);
  const total_net_minutes = days.reduce((acc, d) => acc + (d.net_minutes ?? 0), 0);

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_history",
    http_status: 200,
  }).catch(() => undefined);

  return {
    employee_id,
    tenant_id,
    from: String(payload.from ?? from),
    to: String(payload.to ?? to),
    days,
    total_net_minutes,
  };
}

export class HistoryError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "HistoryError";
  }
}

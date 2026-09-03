import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalMyShiftSlot {
  id: string;
  slot_date: string;
  start_time: string;
  end_time: string;
  spans_midnight: boolean;
  status: string;
  shift_id: string | null;
  shift_name: string;
  shift_color: string | null;
  site_id: string | null;
  location_id: string | null;
  location_name: string | null;
  location_path: string | null;
  publication_id: string | null;
  published_at: string | null;
  notes: string | null;
}

export interface PortalMyShiftsPayload {
  employee_id: string;
  tenant_id: string;
  from: string;
  to: string;
  slots: PortalMyShiftSlot[];
}

function mapSlot(raw: Record<string, unknown>): PortalMyShiftSlot {
  return {
    id: String(raw.id ?? ""),
    slot_date: String(raw.slot_date ?? ""),
    start_time: String(raw.start_time ?? "").slice(0, 5),
    end_time: String(raw.end_time ?? "").slice(0, 5),
    spans_midnight: Boolean(raw.spans_midnight),
    status: String(raw.status ?? "published"),
    shift_id: raw.shift_id == null ? null : String(raw.shift_id),
    shift_name: String(raw.shift_name ?? ""),
    shift_color: raw.shift_color == null ? null : String(raw.shift_color),
    site_id: raw.site_id == null ? null : String(raw.site_id),
    location_id: raw.location_id == null ? null : String(raw.location_id),
    location_name: raw.location_name == null ? null : String(raw.location_name),
    location_path: raw.location_path == null ? null : String(raw.location_path),
    publication_id: raw.publication_id == null ? null : String(raw.publication_id),
    published_at: raw.published_at == null ? null : String(raw.published_at),
    notes: raw.notes == null ? null : String(raw.notes),
  };
}

export async function getPortalMyShifts(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  from: string,
  to: string,
): Promise<PortalMyShiftsPayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_my_shifts", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_from: from,
    p_to: to,
  });

  if (error) {
    const message = error.message ?? "shifts_failed";
    if (message.includes("employee_not_found")) {
      throw new MyShiftsError("employee_not_found", 404, message);
    }
    if (message.includes("invalid_date_range") || message.includes("date_range_too_large")) {
      throw new MyShiftsError("invalid_date_range", 400, message);
    }
    throw new MyShiftsError("shifts_failed", 500, message);
  }

  const payload = data as Record<string, unknown>;
  const slotsRaw = Array.isArray(payload.slots) ? payload.slots : [];

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_my_shifts",
    http_status: 200,
  }).catch(() => undefined);

  return {
    employee_id,
    tenant_id,
    from: String(payload.from ?? from),
    to: String(payload.to ?? to),
    slots: slotsRaw.map((s) => mapSlot(s as Record<string, unknown>)),
  };
}

export class MyShiftsError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "MyShiftsError";
  }
}

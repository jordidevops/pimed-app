import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalSwapRequest {
  id: string;
  kind: string;
  status: string;
  requester_slot_id: string;
  target_slot_id: string | null;
  target_employee_id: string | null;
  requester_notes: string | null;
  created_at: string;
  slot_date: string;
  start_time: string;
  end_time: string;
  is_mine: boolean;
  is_target: boolean;
}

export async function getPortalShiftSwaps(
  employee_id: string,
  tenant_id: string,
  token_id: string,
): Promise<{ requests: PortalSwapRequest[] }> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("employee_portal_list_shift_swaps", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });
  if (error) {
    throw new SwapsError("swaps_failed", 500, error.message);
  }
  const payload = data as Record<string, unknown>;
  const raw = Array.isArray(payload.requests) ? payload.requests : [];

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_swaps",
    http_status: 200,
  }).catch(() => undefined);

  return {
    requests: raw.map((r) => {
      const row = r as Record<string, unknown>;
      return {
        id: String(row.id ?? ""),
        kind: String(row.kind ?? ""),
        status: String(row.status ?? ""),
        requester_slot_id: String(row.requester_slot_id ?? ""),
        target_slot_id: row.target_slot_id == null ? null : String(row.target_slot_id),
        target_employee_id: row.target_employee_id == null ? null : String(row.target_employee_id),
        requester_notes: row.requester_notes == null ? null : String(row.requester_notes),
        created_at: String(row.created_at ?? ""),
        slot_date: String(row.slot_date ?? "").slice(0, 10),
        start_time: String(row.start_time ?? "").slice(0, 5),
        end_time: String(row.end_time ?? "").slice(0, 5),
        is_mine: Boolean(row.is_mine),
        is_target: Boolean(row.is_target),
      };
    }),
  };
}

export async function requestPortalShiftSwap(input: {
  employee_id: string;
  tenant_id: string;
  token_id: string;
  requester_slot_id: string;
  kind: "give_away" | "call_off";
  notes?: string | null;
  target_employee_id?: string | null;
}): Promise<Record<string, unknown>> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("employee_portal_request_shift_swap", {
    p_employee_id: input.employee_id,
    p_tenant_id: input.tenant_id,
    p_requester_slot_id: input.requester_slot_id,
    p_kind: input.kind,
    p_notes: input.notes ?? null,
    p_target_employee_id: input.target_employee_id ?? null,
  });
  if (error) {
    const message = error.message ?? "request_failed";
    if (message.includes("swap_request_already_pending")) {
      throw new SwapsError("already_pending", 409, message);
    }
    if (message.includes("slot_not_published") || message.includes("slot_not_found")) {
      throw new SwapsError("slot_unavailable", 409, message);
    }
    throw new SwapsError("request_failed", 500, message);
  }

  await recordAccessLog({
    token_id: input.token_id,
    employee_id: input.employee_id,
    tenant_id: input.tenant_id,
    action: "request_swap",
    http_status: 200,
    metadata: { kind: input.kind, slot_id: input.requester_slot_id },
  }).catch(() => undefined);

  return (data ?? {}) as Record<string, unknown>;
}

export class SwapsError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "SwapsError";
  }
}

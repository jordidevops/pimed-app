import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalOpeningClaim {
  id: string;
  status: string;
  claimed_at: string;
  notes: string | null;
}

export interface PortalShiftOpening {
  id: string;
  opening_date: string;
  start_time: string;
  end_time: string;
  spans_midnight: boolean;
  places_total: number;
  places_filled: number;
  places_remaining: number;
  claim_policy: string;
  title: string | null;
  notes: string | null;
  compensation_label: string | null;
  role_id: string | null;
  role_name: string | null;
  location_id: string | null;
  location_name: string | null;
  site_id: string;
  closes_at: string | null;
  eligible: boolean;
  eligibility: {
    ok?: boolean;
    blocks?: string[];
    warnings?: string[];
  };
  my_claim: PortalOpeningClaim | null;
}

export interface PortalShiftOpeningsPayload {
  employee_id: string;
  tenant_id: string;
  site_id: string;
  from: string;
  to: string;
  openings: PortalShiftOpening[];
}

function time5(raw: unknown): string {
  const s = String(raw ?? "");
  return s.length >= 5 ? s.slice(0, 5) : s;
}

function mapOpening(raw: Record<string, unknown>): PortalShiftOpening {
  const myClaimRaw = raw.my_claim as Record<string, unknown> | null | undefined;
  const elig = (raw.eligibility as Record<string, unknown> | null) ?? {};
  return {
    id: String(raw.id ?? ""),
    opening_date: String(raw.opening_date ?? "").slice(0, 10),
    start_time: time5(raw.start_time),
    end_time: time5(raw.end_time),
    spans_midnight: Boolean(raw.spans_midnight),
    places_total: Number(raw.places_total ?? 1),
    places_filled: Number(raw.places_filled ?? 0),
    places_remaining: Number(raw.places_remaining ?? 0),
    claim_policy: String(raw.claim_policy ?? "manager_approval"),
    title: raw.title == null ? null : String(raw.title),
    notes: raw.notes == null ? null : String(raw.notes),
    compensation_label: raw.compensation_label == null ? null : String(raw.compensation_label),
    role_id: raw.role_id == null ? null : String(raw.role_id),
    role_name: raw.role_name == null ? null : String(raw.role_name),
    location_id: raw.location_id == null ? null : String(raw.location_id),
    location_name: raw.location_name == null ? null : String(raw.location_name),
    site_id: String(raw.site_id ?? ""),
    closes_at: raw.closes_at == null ? null : String(raw.closes_at),
    eligible: Boolean(raw.eligible),
    eligibility: {
      ok: elig.ok as boolean | undefined,
      blocks: Array.isArray(elig.blocks) ? (elig.blocks as string[]) : [],
      warnings: Array.isArray(elig.warnings) ? (elig.warnings as string[]) : [],
    },
    my_claim: myClaimRaw
      ? {
        id: String(myClaimRaw.id ?? ""),
        status: String(myClaimRaw.status ?? ""),
        claimed_at: String(myClaimRaw.claimed_at ?? ""),
        notes: myClaimRaw.notes == null ? null : String(myClaimRaw.notes),
      }
      : null,
  };
}

export async function getPortalShiftOpenings(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  from: string,
  to: string,
): Promise<PortalShiftOpeningsPayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_list_shift_openings", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_from: from,
    p_to: to,
  });

  if (error) {
    const message = error.message ?? "openings_failed";
    if (message.includes("employee_not_found")) {
      throw new OpeningsError("employee_not_found", 404, message);
    }
    if (message.includes("invalid_date_range") || message.includes("date_range_too_large")) {
      throw new OpeningsError("invalid_date_range", 400, message);
    }
    throw new OpeningsError("openings_failed", 500, message);
  }

  const payload = data as Record<string, unknown>;
  const openingsRaw = Array.isArray(payload.openings) ? payload.openings : [];

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_openings",
    http_status: 200,
  }).catch(() => undefined);

  return {
    employee_id,
    tenant_id,
    site_id: String(payload.site_id ?? ""),
    from: String(payload.from ?? from),
    to: String(payload.to ?? to),
    openings: openingsRaw.map((o) => mapOpening(o as Record<string, unknown>)),
  };
}

export async function claimPortalShiftOpening(input: {
  employee_id: string;
  tenant_id: string;
  token_id: string;
  opening_id: string;
  notes?: string | null;
}): Promise<Record<string, unknown>> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_claim_shift_opening", {
    p_employee_id: input.employee_id,
    p_tenant_id: input.tenant_id,
    p_opening_id: input.opening_id,
    p_notes: input.notes ?? null,
  });

  if (error) {
    const message = error.message ?? "claim_failed";
    if (message.includes("claim_not_eligible") || message.includes("SHIFT_OVERLAP")) {
      throw new OpeningsError("not_eligible", 409, message);
    }
    if (message.includes("claim_already_exists")) {
      throw new OpeningsError("already_claimed", 409, message);
    }
    if (message.includes("opening_full") || message.includes("opening_not_open")) {
      throw new OpeningsError("opening_unavailable", 409, message);
    }
    if (message.includes("opening_not_found")) {
      throw new OpeningsError("opening_not_found", 404, message);
    }
    throw new OpeningsError("claim_failed", 500, message);
  }

  await recordAccessLog({
    token_id: input.token_id,
    employee_id: input.employee_id,
    tenant_id: input.tenant_id,
    action: "claim_opening",
    http_status: 200,
    metadata: { opening_id: input.opening_id },
  }).catch(() => undefined);

  return (data ?? {}) as Record<string, unknown>;
}

export async function withdrawPortalShiftOpeningClaim(input: {
  employee_id: string;
  tenant_id: string;
  token_id: string;
  claim_id: string;
}): Promise<Record<string, unknown>> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_withdraw_shift_opening_claim", {
    p_employee_id: input.employee_id,
    p_tenant_id: input.tenant_id,
    p_claim_id: input.claim_id,
  });

  if (error) {
    const message = error.message ?? "withdraw_failed";
    if (message.includes("claim_not_pending")) {
      throw new OpeningsError("claim_not_pending", 409, message);
    }
    if (message.includes("claim_not_found")) {
      throw new OpeningsError("claim_not_found", 404, message);
    }
    throw new OpeningsError("withdraw_failed", 500, message);
  }

  await recordAccessLog({
    token_id: input.token_id,
    employee_id: input.employee_id,
    tenant_id: input.tenant_id,
    action: "withdraw_opening_claim",
    http_status: 200,
    metadata: { claim_id: input.claim_id },
  }).catch(() => undefined);

  return (data ?? {}) as Record<string, unknown>;
}

export class OpeningsError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "OpeningsError";
  }
}

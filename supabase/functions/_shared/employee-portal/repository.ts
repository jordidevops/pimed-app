/**
 * EmployeePortalRepository — EP2
 * Accés via RPCs api.* (PostgREST no exposa schema data).
 */
import { createAdminClient } from "../supabase.ts";
import { sha256Bytes, bytesToHex } from "./crypto.ts";
import type { PortalPublicPolicy, TokenRecord } from "./types.ts";

const DEFAULT_PORTAL_POLICY: PortalPublicPolicy = {
  default_pin_required: true,
};

type TokenPayload = {
  token_id: string;
  tenant_id: string;
  employee_id: string;
  full_name: string;
  session_version: number;
  is_active: boolean;
  revoked_at: string | null;
  expires_at: string | null;
  compromised: boolean;
  pin_required: boolean;
  pin_must_set?: boolean;
  pin_hash?: string | null;
  pin_attempts?: number;
  pin_locked_until?: string | null;
  identity_verified_at?: string | null;
  identity_required?: boolean;
  has_document_id?: boolean;
  identity_attempts?: number;
  identity_locked_until?: string | null;
};

function mapPayload(payload: TokenPayload): TokenRecord {
  return {
    token_id: payload.token_id,
    tenant_id: payload.tenant_id,
    employee_id: payload.employee_id,
    full_name: payload.full_name,
    session_version: payload.session_version,
    is_active: payload.is_active,
    revoked_at: payload.revoked_at,
    expires_at: payload.expires_at,
    compromised: payload.compromised,
    pin_required: payload.pin_required,
    pin_must_set: payload.pin_must_set ?? false,
    pin_hash: payload.pin_hash ?? null,
    pin_attempts: payload.pin_attempts ?? 0,
    pin_locked_until: payload.pin_locked_until ?? null,
    identity_verified_at: payload.identity_verified_at ?? null,
    identity_required: payload.identity_required ?? false,
    has_document_id: payload.has_document_id ?? true,
    identity_attempts: payload.identity_attempts ?? 0,
    identity_locked_until: payload.identity_locked_until ?? null,
  };
}

function isTokenNotExpired(record: TokenRecord): boolean {
  if (!record.expires_at) return true;
  return new Date(record.expires_at).getTime() > Date.now();
}

export function isTokenSessionValid(record: TokenRecord, session_version: number): boolean {
  if (!record.is_active) return false;
  if (record.revoked_at) return false;
  if (!isTokenNotExpired(record)) return false;
  if (record.session_version !== session_version) return false;
  return true;
}

export async function lookupTokenBySecret(secret: string): Promise<TokenRecord | null> {
  const normalized = secret.trim();
  if (!normalized) return null;
  const hashHex = bytesToHex(await sha256Bytes(normalized));
  const db = createAdminClient();

  const { data, error } = await db.rpc("lookup_employee_portal_token_by_hash", {
    p_token_hash_hex: hashHex,
  });

  if (error) {
    throw new Error(`lookupTokenBySecret failed: ${error.message}`);
  }
  if (!data) return null;

  return mapPayload(data as TokenPayload);
}

export async function getTokenById(token_id: string): Promise<TokenRecord | null> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("get_employee_portal_token_session", {
    p_token_id: token_id,
  });

  if (error) {
    throw new Error(`getTokenById failed: ${error.message}`);
  }
  if (!data) return null;

  return mapPayload(data as TokenPayload);
}

export async function recordAccessLog(input: {
  token_id: string;
  employee_id: string;
  tenant_id: string;
  action: string;
  http_status?: number;
  failure_reason?: string | null;
  ip_address?: string | null;
  user_agent?: string | null;
  metadata?: Record<string, unknown> | null;
}): Promise<void> {
  const db = createAdminClient();

  const { error } = await db.rpc("log_employee_portal_access_event", {
    p_token_id: input.token_id,
    p_employee_id: input.employee_id,
    p_tenant_id: input.tenant_id,
    p_action: input.action,
    p_http_status: input.http_status ?? null,
    p_failure_reason: input.failure_reason ?? null,
    p_ip_address: input.ip_address ?? null,
    p_user_agent: input.user_agent ?? null,
    p_metadata: input.metadata ?? null,
  });

  if (error) {
    console.warn("[employee-portal] access log failed:", error.message);
  }
}

export async function attemptEmployeePortalPin(
  token_id: string,
  pin_hash: string,
): Promise<{
  status: "ok" | "invalid" | "locked" | "not_required" | "invalid_token";
  pin_attempts?: number;
  retry_after_seconds?: number;
}> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_attempt_pin", {
    p_token_id: token_id,
    p_pin_hash: pin_hash,
  });

  if (error) {
    throw new Error(`attemptEmployeePortalPin failed: ${error.message}`);
  }

  const payload = data as {
    status?: string;
    pin_attempts?: number;
    retry_after_seconds?: number;
  } | null;

  return {
    status: (payload?.status ?? "invalid_token") as
      | "ok"
      | "invalid"
      | "locked"
      | "not_required"
      | "invalid_token",
    pin_attempts: payload?.pin_attempts,
    retry_after_seconds: payload?.retry_after_seconds,
  };
}

export async function verifyEmployeePortalIdentityDocument(
  token_hash_hex: string,
  document_id: string,
): Promise<{
  status: string;
  full_name?: string;
  token_id?: string;
  tenant_id?: string;
  employee_id?: string;
  identity_attempts?: number;
  retry_after_seconds?: number;
}> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_verify_identity_document", {
    p_token_hash_hex: token_hash_hex,
    p_document_id: document_id,
  });

  if (error) {
    throw new Error(`verifyEmployeePortalIdentityDocument failed: ${error.message}`);
  }

  const payload = data as {
    status?: string;
    full_name?: string;
    token_id?: string;
    tenant_id?: string;
    employee_id?: string;
    identity_attempts?: number;
    retry_after_seconds?: number;
  } | null;

  return {
    status: payload?.status ?? "token_invalid",
    full_name: payload?.full_name,
    token_id: payload?.token_id,
    tenant_id: payload?.tenant_id,
    employee_id: payload?.employee_id,
    identity_attempts: payload?.identity_attempts,
    retry_after_seconds: payload?.retry_after_seconds,
  };
}

export async function confirmEmployeePortalIdentity(
  token_hash_hex: string,
): Promise<{
  status: string;
  next?: "pin_setup" | "pin" | "ready";
  full_name?: string;
  token_id?: string;
  tenant_id?: string;
  employee_id?: string;
}> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_confirm_identity", {
    p_token_hash_hex: token_hash_hex,
  });

  if (error) {
    throw new Error(`confirmEmployeePortalIdentity failed: ${error.message}`);
  }

  const payload = data as {
    status?: string;
    next?: "pin_setup" | "pin" | "ready";
    full_name?: string;
    token_id?: string;
    tenant_id?: string;
    employee_id?: string;
  } | null;

  return {
    status: payload?.status ?? "token_invalid",
    next: payload?.next,
    full_name: payload?.full_name,
    token_id: payload?.token_id,
    tenant_id: payload?.tenant_id,
    employee_id: payload?.employee_id,
  };
}

export async function clearEmployeePortalIdentityChallenge(
  token_hash_hex: string,
): Promise<{ status: string; token_id?: string }> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_clear_identity_challenge", {
    p_token_hash_hex: token_hash_hex,
  });

  if (error) {
    throw new Error(`clearEmployeePortalIdentityChallenge failed: ${error.message}`);
  }

  const payload = data as { status?: string; token_id?: string } | null;
  return {
    status: payload?.status ?? "token_invalid",
    token_id: payload?.token_id,
  };
}

export async function setupEmployeePortalPin(
  token_hash_hex: string,
  pin_hash: string,
): Promise<
  TokenPayload | { status: "pin_already_set" | "token_invalid" | "identity_required" }
> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_setup_pin", {
    p_token_hash_hex: token_hash_hex,
    p_pin_hash: pin_hash,
  });

  if (error) {
    throw new Error(`setupEmployeePortalPin failed: ${error.message}`);
  }

  const payload = data as TokenPayload & { status?: string } | null;
  if (!payload || payload.status === "pin_already_set") {
    return { status: "pin_already_set" };
  }
  if (payload.status === "identity_required") {
    return { status: "identity_required" };
  }
  if (payload.status === "token_invalid" || !payload.token_id) {
    return { status: "token_invalid" };
  }

  return payload;
}

export async function changeEmployeePortalPin(
  token_id: string,
  new_pin_hash: string,
): Promise<TokenPayload | { status: "token_invalid" }> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_change_pin", {
    p_token_id: token_id,
    p_new_pin_hash: new_pin_hash,
  });

  if (error) {
    throw new Error(`changeEmployeePortalPin failed: ${error.message}`);
  }

  const payload = data as TokenPayload & { status?: string } | null;
  if (!payload || payload.status === "token_invalid" || !payload.token_id) {
    return { status: "token_invalid" };
  }

  return payload;
}

export async function getEmployeePortalPublicPolicy(
  employee_id: string,
): Promise<PortalPublicPolicy> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("get_employee_portal_public_policy", {
    p_employee_id: employee_id,
  });

  if (error) {
    console.warn("[employee-portal] public policy lookup failed:", error.message);
    return DEFAULT_PORTAL_POLICY;
  }

  const payload = data as PortalPublicPolicy | null;
  if (!payload) return DEFAULT_PORTAL_POLICY;

  return {
    default_pin_required: payload.default_pin_required !== false,
  };
}

export async function revokeTokenById(
  token_id: string,
  compromised = false,
): Promise<boolean> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("revoke_employee_portal_token_system", {
    p_token_id: token_id,
    p_compromised: compromised,
  });

  if (error) {
    console.warn("[employee-portal] revoke failed:", error.message);
    return false;
  }

  return Boolean(data);
}

export async function lookupEmployeePortalPinReset(reset_token_hash_hex: string): Promise<{
  status: string;
  employee_name?: string;
  expires_at?: string;
  reset_id?: string;
  employee_portal_token_id?: string;
  tenant_id?: string;
} | null> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("lookup_employee_portal_pin_reset_by_hash", {
    p_reset_token_hash_hex: reset_token_hash_hex,
  });

  if (error) {
    throw new Error(`lookupEmployeePortalPinReset failed: ${error.message}`);
  }
  if (!data || typeof data !== "object") return null;

  return data as {
    status: string;
    employee_name?: string;
    expires_at?: string;
    reset_id?: string;
    employee_portal_token_id?: string;
    tenant_id?: string;
  };
}

export async function consumeEmployeePortalPinReset(
  reset_token_hash_hex: string,
  new_pin_hash: string,
): Promise<{
  status: string;
  token_id?: string;
  tenant_id?: string;
  employee_id?: string;
  employee_name?: string;
}> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_consume_pin_reset", {
    p_reset_token_hash_hex: reset_token_hash_hex,
    p_new_pin_hash: new_pin_hash,
  });

  if (error) {
    throw new Error(`consumeEmployeePortalPinReset failed: ${error.message}`);
  }

  const payload = data as {
    status?: string;
    token_id?: string;
    tenant_id?: string;
    employee_id?: string;
    employee_name?: string;
  } | null;

  return {
    status: payload?.status ?? "invalid",
    token_id: payload?.token_id,
    tenant_id: payload?.tenant_id,
    employee_id: payload?.employee_id,
    employee_name: payload?.employee_name,
  };
}

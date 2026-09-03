import { signJwt, verifyJwt, verifyJwtAllowExpired } from "./crypto.ts";
import {
  attemptEmployeePortalPin,
  getEmployeePortalPublicPolicy,
  getTokenById,
  isTokenSessionValid,
  lookupTokenBySecret,
  recordAccessLog,
  revokeTokenById,
} from "./repository.ts";
import {
  getTokenById as getDevTokenById,
  lookupTokenBySecret as lookupDevTokenBySecret,
  revokeDevToken,
} from "./dev-token-store.ts";
import { hashPortalPin } from "./pin.ts";
import { getPortalPunchProfile } from "./punch-service.ts";
import type {
  EmployeePortalSessionClaims,
  SessionSuccessResponse,
  TokenRecord,
} from "./types.ts";

const SESSION_MINUTES = Number(Deno.env.get("EMPLOYEE_PORTAL_SESSION_MINUTES") ?? "15");
const USE_DEV_STUB = Deno.env.get("EMPLOYEE_PORTAL_USE_DEV_STUB") === "true";

function getJwtSecret(): string {
  const secret = Deno.env.get("EMPLOYEE_PORTAL_JWT_SECRET");
  if (!secret) {
    throw new Error("EMPLOYEE_PORTAL_JWT_SECRET is not configured");
  }
  return secret;
}

function sessionTtlSeconds(): number {
  return Math.max(60, SESSION_MINUTES * 60);
}

export function assertTokenNotExpired(record: TokenRecord): void {
  if (!record.expires_at) return;
  if (new Date(record.expires_at).getTime() <= Date.now()) {
    throw new SessionError("token_invalid", 401);
  }
}

export function assertPortalIdentityVerified(record: TokenRecord): void {
  if (!record.has_document_id) {
    throw new SessionError("identity_not_configured", 403, "Identity not configured");
  }
  if (record.identity_required && !record.identity_verified_at) {
    throw new SessionError("identity_required", 403, "Identity verification required");
  }
}

async function resolveTokenBySecret(secret: string): Promise<TokenRecord | null> {
  const dbToken = await lookupTokenBySecret(secret);
  if (dbToken) return dbToken;
  if (USE_DEV_STUB) {
    return lookupDevTokenBySecret(secret);
  }
  return null;
}

async function resolveTokenById(token_id: string): Promise<TokenRecord | null> {
  const dbToken = await getTokenById(token_id);
  if (dbToken) return dbToken;
  if (USE_DEV_STUB) {
    return getDevTokenById(token_id) ?? null;
  }
  return null;
}

function assertTokenSession(record: TokenRecord, session_version: number): void {
  if (record.compromised) {
    throw new SessionError("token_revoked", 401);
  }
  if (!isTokenSessionValid(record, session_version)) {
    throw new SessionError("token_revoked", 401);
  }
}

export async function validatePortalPinAttempt(
  record: TokenRecord,
  pin?: string | null,
): Promise<void> {
  if (record.pin_must_set || !record.pin_hash) {
    return;
  }

  if (!pin) {
    throw new SessionError("pin_required", 403, "PIN required");
  }

  const pinHash = await hashPortalPin(pin);
  const result = await attemptEmployeePortalPin(record.token_id, pinHash);

  if (result.status === "locked") {
    await recordAccessLog({
      token_id: record.token_id,
      employee_id: record.employee_id,
      tenant_id: record.tenant_id,
      action: "pin_locked",
      http_status: 423,
      failure_reason: "pin_locked",
    }).catch(() => undefined);
    throw new SessionError(
      "pin_locked",
      423,
      "PIN locked",
      result.retry_after_seconds,
    );
  }

  if (result.status !== "ok") {
    await recordAccessLog({
      token_id: record.token_id,
      employee_id: record.employee_id,
      tenant_id: record.tenant_id,
      action: "pin_failed",
      http_status: 401,
      failure_reason: "pin_invalid",
    }).catch(() => undefined);
    throw new SessionError("pin_invalid", 401, "Invalid PIN");
  }
}

export async function createPortalSession(
  secret: string,
  pin?: string | null,
): Promise<SessionSuccessResponse> {
  const record = await resolveTokenBySecret(secret);
  if (!record || !record.is_active || record.revoked_at) {
    throw new SessionError("token_invalid", 401);
  }
  assertTokenNotExpired(record);

  assertPortalIdentityVerified(record);

  if (record.pin_must_set) {
    throw new SessionError("pin_setup_required", 403, "PIN setup required");
  }

  if (record.pin_required && record.pin_hash) {
    await validatePortalPinAttempt(record, pin);
  }

  const session = await issueSessionForRecord(record);

  await recordAccessLog({
    token_id: record.token_id,
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    action: "session_create",
    http_status: 200,
  }).catch(() => undefined);

  return session;
}

export async function getPortalSessionMe(
  sessionToken: string,
): Promise<SessionSuccessResponse> {
  const payload = await verifyJwt(sessionToken, getJwtSecret());
  if (!payload) {
    throw new SessionError("session_expired", 401);
  }

  const claims = payload as unknown as EmployeePortalSessionClaims;
  if (claims.sub !== "employee_portal") {
    throw new SessionError("session_invalid", 401);
  }

  const record = await resolveTokenById(claims.token_id);
  if (!record) {
    throw new SessionError("token_invalid", 401);
  }

  assertTokenSession(record, claims.session_version);

  return buildExistingSessionResponse(record, sessionToken, claims);
}

export async function refreshPortalSession(
  sessionToken: string,
  pin?: string | null,
): Promise<SessionSuccessResponse> {
  let payload = await verifyJwt(sessionToken, getJwtSecret());
  const jwtWasExpired = !payload;
  if (!payload) {
    payload = await verifyJwtAllowExpired(sessionToken, getJwtSecret());
    if (!payload) {
      throw new SessionError("session_expired", 401);
    }
  }

  const claims = payload as unknown as EmployeePortalSessionClaims;
  if (claims.sub !== "employee_portal") {
    throw new SessionError("session_invalid", 401);
  }

  const record = await resolveTokenById(claims.token_id);
  if (!record) {
    throw new SessionError("token_invalid", 401);
  }

  if (jwtWasExpired && record.pin_required && record.pin_hash) {
    await validatePortalPinAttempt(record, pin);
  }

  assertTokenSession(record, claims.session_version);

  const session = await issueSessionForRecord(record);

  await recordAccessLog({
    token_id: record.token_id,
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    action: "session_refresh",
    http_status: 200,
  }).catch(() => undefined);

  return session;
}

export async function revokePortalToken(
  token_id: string,
  compromised = false,
): Promise<boolean> {
  const revoked = await revokeTokenById(token_id, compromised);
  if (revoked) return true;
  if (USE_DEV_STUB) {
    return revokeDevToken(token_id, compromised);
  }
  return false;
}

async function issueSession(record: TokenRecord): Promise<SessionSuccessResponse> {
  return issueSessionForRecord(record);
}

export async function issueSessionForRecord(
  record: TokenRecord,
): Promise<SessionSuccessResponse> {
  const now = Math.floor(Date.now() / 1000);
  const expiresIn = sessionTtlSeconds();
  const claims: EmployeePortalSessionClaims = {
    sub: "employee_portal",
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    token_id: record.token_id,
    session_version: record.session_version,
    iat: now,
    exp: now + expiresIn,
  };

  const session_token = await signJwt(claims as unknown as Record<string, unknown>, getJwtSecret());
  const portal_policy = await getEmployeePortalPublicPolicy(record.employee_id);

  let punchProfile = { work_profile: "fixed_site", legacy_in_out_only: true };
  try {
    punchProfile = await getPortalPunchProfile(record.employee_id, record.tenant_id);
  } catch (err) {
    console.warn("[employee-portal] punch profile lookup failed:", err);
  }

  return {
    session_token,
    expires_in: expiresIn,
    portal_policy,
    employee: {
      id: record.employee_id,
      tenant_id: record.tenant_id,
      full_name: record.full_name,
      pin_required: record.pin_required,
      work_profile: punchProfile.work_profile,
      legacy_in_out_only: punchProfile.legacy_in_out_only,
    },
  };
}

async function buildExistingSessionResponse(
  record: TokenRecord,
  sessionToken: string,
  claims: EmployeePortalSessionClaims,
): Promise<SessionSuccessResponse> {
  const now = Math.floor(Date.now() / 1000);
  const expiresIn = Math.max(0, claims.exp - now);
  const portal_policy = await getEmployeePortalPublicPolicy(record.employee_id);

  let punchProfile = { work_profile: "fixed_site", legacy_in_out_only: true };
  try {
    punchProfile = await getPortalPunchProfile(record.employee_id, record.tenant_id);
  } catch (err) {
    console.warn("[employee-portal] punch profile lookup failed:", err);
  }

  return {
    session_token: sessionToken,
    expires_in: expiresIn,
    portal_policy,
    employee: {
      id: record.employee_id,
      tenant_id: record.tenant_id,
      full_name: record.full_name,
      pin_required: record.pin_required,
      work_profile: punchProfile.work_profile,
      legacy_in_out_only: punchProfile.legacy_in_out_only,
    },
  };
}

export class SessionError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
    public readonly retryAfterSeconds?: number,
  ) {
    super(message ?? code);
    this.name = "SessionError";
  }
}

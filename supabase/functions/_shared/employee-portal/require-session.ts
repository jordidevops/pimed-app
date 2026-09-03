import { verifyJwt, verifyJwtAllowExpired } from "./crypto.ts";
import { getTokenById, isTokenSessionValid } from "./repository.ts";
import {
  getTokenById as getDevTokenById,
} from "./dev-token-store.ts";
import { SessionError } from "./session-service.ts";
import type { EmployeePortalSessionClaims, TokenRecord } from "./types.ts";

const USE_DEV_STUB = Deno.env.get("EMPLOYEE_PORTAL_USE_DEV_STUB") === "true";

function getJwtSecret(): string {
  const secret = Deno.env.get("EMPLOYEE_PORTAL_JWT_SECRET");
  if (!secret) {
    throw new Error("EMPLOYEE_PORTAL_JWT_SECRET is not configured");
  }
  return secret;
}

async function resolveTokenById(token_id: string): Promise<TokenRecord | null> {
  const dbToken = await getTokenById(token_id);
  if (dbToken) return dbToken;
  if (USE_DEV_STUB) {
    return getDevTokenById(token_id) ?? null;
  }
  return null;
}

export async function requirePortalSession(
  sessionToken: string | null,
): Promise<{ claims: EmployeePortalSessionClaims; record: TokenRecord }> {
  if (!sessionToken) {
    throw new SessionError("missing_session", 401);
  }

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

  if (record.compromised) {
    throw new SessionError("token_revoked", 401);
  }

  if (!isTokenSessionValid(record, claims.session_version)) {
    throw new SessionError("token_revoked", 401);
  }

  return { claims, record };
}

function isOfflinePreRevocationPunch(
  record: TokenRecord,
  occurred_at: string | undefined,
): boolean {
  if (!occurred_at || !record.revoked_at) return false;
  return new Date(occurred_at).getTime() < new Date(record.revoked_at).getTime();
}

/**
 * Autoritza un punch de portal. Permet JWT caducat i token revocat quan
 * `occurred_at` és anterior a `revoked_at` (sync offline EP2/EP5).
 */
export async function authorizePortalPunch(
  sessionToken: string | null,
  occurred_at?: string,
): Promise<{ claims: EmployeePortalSessionClaims; record: TokenRecord }> {
  if (!sessionToken) {
    throw new SessionError("missing_session", 401);
  }

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

  if (record.compromised) {
    throw new SessionError("token_revoked", 403);
  }

  if (isOfflinePreRevocationPunch(record, occurred_at)) {
    return { claims, record };
  }

  if (jwtWasExpired) {
    throw new SessionError("session_expired", 401);
  }

  if (record.revoked_at || !record.is_active) {
    throw new SessionError("token_revoked", 403);
  }

  if (!isTokenSessionValid(record, claims.session_version)) {
    throw new SessionError("token_revoked", 403);
  }

  return { claims, record };
}

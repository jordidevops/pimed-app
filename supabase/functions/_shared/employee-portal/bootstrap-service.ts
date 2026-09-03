import { sha256Bytes, bytesToHex } from "./crypto.ts";
import { lookupTokenBySecret as lookupDevTokenBySecret } from "./dev-token-store.ts";
import {
  identityLockedRetrySeconds,
  isIdentityLocked,
  resolvePortalBootstrapState,
  type PortalBootstrapState,
} from "./identity-utils.ts";
import { lookupTokenBySecret } from "./repository.ts";
import type { TokenRecord } from "./types.ts";

const USE_DEV_STUB = Deno.env.get("EMPLOYEE_PORTAL_USE_DEV_STUB") === "true";

export interface PortalBootstrapStateResponse {
  state: PortalBootstrapState;
  full_name?: string;
  identity_locked?: boolean;
  retry_after_seconds?: number;
}

export async function resolveTokenBySecret(secret: string): Promise<TokenRecord | null> {
  const dbToken = await lookupTokenBySecret(secret);
  if (dbToken) return dbToken;
  if (USE_DEV_STUB) {
    return lookupDevTokenBySecret(secret);
  }
  return null;
}

export async function getPortalBootstrapState(
  secret: string,
): Promise<PortalBootstrapStateResponse> {
  const record = await resolveTokenBySecret(secret.trim());
  if (!record) {
    return { state: "token_invalid" };
  }

  const state = resolvePortalBootstrapState(record);
  const response: PortalBootstrapStateResponse = { state };

  if (state !== "token_invalid" && state !== "requires_identity" && state !== "identity_not_configured") {
    response.full_name = record.full_name;
  }

  if (state === "requires_identity" && isIdentityLocked(record)) {
    response.identity_locked = true;
    response.retry_after_seconds = identityLockedRetrySeconds(record);
  }

  return response;
}

export async function secretToHashHex(secret: string): Promise<string> {
  return bytesToHex(await sha256Bytes(secret.trim()));
}

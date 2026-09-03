import type { TokenRecord } from "./types.ts";

export type PortalBootstrapState =
  | "token_invalid"
  | "identity_not_configured"
  | "requires_identity"
  | "pin_setup"
  | "pin"
  | "ready";

export function isIdentityLocked(record: TokenRecord): boolean {
  if (!record.identity_locked_until) return false;
  return new Date(record.identity_locked_until).getTime() > Date.now();
}

export function identityLockedRetrySeconds(record: TokenRecord): number | undefined {
  if (!isIdentityLocked(record)) return undefined;
  const remainingMs = new Date(record.identity_locked_until!).getTime() - Date.now();
  return Math.max(1, Math.ceil(remainingMs / 1000));
}

export function isIdentityVerified(record: TokenRecord): boolean {
  return Boolean(record.identity_verified_at);
}

export function needsIdentityVerification(record: TokenRecord): boolean {
  if (!record.has_document_id) return false;
  return record.identity_required && !isIdentityVerified(record);
}

export function resolvePortalBootstrapState(record: TokenRecord): PortalBootstrapState {
  if (!record.is_active || record.revoked_at) {
    return "token_invalid";
  }
  if (record.expires_at && new Date(record.expires_at).getTime() <= Date.now()) {
    return "token_invalid";
  }

  if (!record.has_document_id) {
    return "identity_not_configured";
  }

  if (needsIdentityVerification(record)) {
    return "requires_identity";
  }

  if (!record.pin_hash && record.pin_must_set) {
    return "pin_setup";
  }

  if (record.pin_required && record.pin_hash) {
    return "pin";
  }

  return "ready";
}

export function resolvePortalNextStep(record: TokenRecord): "pin_setup" | "pin" | "ready" {
  const state = resolvePortalBootstrapState(record);
  if (state === "pin_setup") return "pin_setup";
  if (state === "pin") return "pin";
  return "ready";
}

export function documentIdLast4(documentId: string): string | null {
  const normalized = documentId.replace(/[^0-9A-Za-z]/g, "").toUpperCase();
  if (normalized.length < 4) return null;
  return normalized.slice(-4);
}

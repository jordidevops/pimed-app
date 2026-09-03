import { resolveTokenBySecret, secretToHashHex } from "./bootstrap-service.ts";
import { hashPortalPin, isValidPortalPin } from "./pin.ts";
import {
  changeEmployeePortalPin,
  recordAccessLog,
  setupEmployeePortalPin,
} from "./repository.ts";
import {
  assertPortalIdentityVerified,
  assertTokenNotExpired,
  issueSessionForRecord,
  SessionError,
  validatePortalPinAttempt,
} from "./session-service.ts";
import type { SessionSuccessResponse, TokenRecord } from "./types.ts";

type SetupPinPayload = {
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
  pin_must_set: boolean;
  pin_hash: string | null;
  pin_attempts?: number;
  pin_locked_until?: string | null;
};

function payloadToRecord(payload: SetupPinPayload): TokenRecord {
  return {
    token_id: payload.token_id,
    tenant_id: payload.tenant_id,
    employee_id: payload.employee_id,
    full_name: payload.full_name,
    secret_hash: new Uint8Array(),
    session_version: payload.session_version,
    is_active: payload.is_active,
    revoked_at: payload.revoked_at,
    expires_at: payload.expires_at,
    compromised: payload.compromised,
    pin_required: payload.pin_required,
    pin_must_set: payload.pin_must_set,
    pin_hash: payload.pin_hash,
    pin_attempts: payload.pin_attempts ?? 0,
    pin_locked_until: payload.pin_locked_until ?? null,
  };
}

export async function setupPortalPin(
  secret: string,
  pin: string,
  confirmPin: string,
): Promise<SessionSuccessResponse> {
  if (!isValidPortalPin(pin)) {
    throw new SessionError("invalid_pin", 400, "PIN must be 4-6 digits");
  }
  if (pin !== confirmPin) {
    throw new SessionError("pin_mismatch", 400, "PIN confirmation does not match");
  }

  const pinHash = await hashPortalPin(pin);
  const tokenHashHex = await secretToHashHex(secret.trim());

  const normalizedSecret = secret.trim();
  const tokenRecord = await resolveTokenBySecret(normalizedSecret);
  if (!tokenRecord || !tokenRecord.is_active || tokenRecord.revoked_at) {
    throw new SessionError("token_invalid", 401);
  }
  assertTokenNotExpired(tokenRecord);
  assertPortalIdentityVerified(tokenRecord);

  if (tokenRecord.pin_hash && !tokenRecord.pin_must_set) {
    throw new SessionError("pin_already_set", 409, "PIN already set");
  }

  if (!tokenRecord.pin_must_set && !tokenRecord.pin_hash) {
    throw new SessionError("pin_setup_not_required", 403, "PIN setup not required");
  }

  const result = await setupEmployeePortalPin(tokenHashHex, pinHash);

  if ("status" in result) {
    if (result.status === "identity_required") {
      throw new SessionError("identity_required", 403, "Identity verification required");
    }
    if (result.status === "pin_already_set") {
      throw new SessionError("pin_already_set", 409, "PIN already set");
    }

    const latest = await resolveTokenBySecret(normalizedSecret);
    if (latest?.pin_hash && !latest.pin_must_set) {
      throw new SessionError("pin_already_set", 409, "PIN already set");
    }

    throw new SessionError("token_invalid", 401);
  }

  const record = payloadToRecord(result as SetupPinPayload);
  const session = await issueSessionForRecord(record);

  await recordAccessLog({
    token_id: record.token_id,
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    action: "pin_setup",
    http_status: 200,
  }).catch(() => undefined);

  await recordAccessLog({
    token_id: record.token_id,
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    action: "session_create",
    http_status: 200,
  }).catch(() => undefined);

  return session;
}

export async function changePortalPin(
  record: TokenRecord,
  currentPin: string,
  newPin: string,
  confirmPin: string,
): Promise<void> {
  if (!isValidPortalPin(newPin)) {
    throw new SessionError("invalid_pin", 400, "PIN must be 4-6 digits");
  }
  if (newPin !== confirmPin) {
    throw new SessionError("pin_mismatch", 400, "PIN confirmation does not match");
  }
  if (currentPin === newPin) {
    throw new SessionError("pin_unchanged", 400, "New PIN must differ from current PIN");
  }

  await validatePortalPinAttempt(record, currentPin);

  const newPinHash = await hashPortalPin(newPin);
  const result = await changeEmployeePortalPin(record.token_id, newPinHash);

  if ("status" in result) {
    throw new SessionError("token_invalid", 401);
  }

  await recordAccessLog({
    token_id: record.token_id,
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    action: "pin_changed",
    http_status: 200,
  }).catch(() => undefined);
}

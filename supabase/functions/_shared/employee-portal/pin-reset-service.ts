import { sha256Bytes, bytesToHex } from "./crypto.ts";
import { hashPortalPin, isValidPortalPin } from "./pin.ts";
import {
  consumeEmployeePortalPinReset,
  lookupEmployeePortalPinReset,
  recordAccessLog,
} from "./repository.ts";
import { SessionError } from "./session-service.ts";

async function secretToHashHex(secret: string): Promise<string> {
  return bytesToHex(await sha256Bytes(secret.trim()));
}

export async function validatePortalPinReset(secret: string): Promise<{
  valid: true;
  employee_name: string;
  expires_at: string;
}> {
  const hashHex = await secretToHashHex(secret);
  const result = await lookupEmployeePortalPinReset(hashHex);

  if (!result) {
    throw new SessionError("pin_reset_invalid", 404, "Invalid reset link");
  }

  if (result.status === "used") {
    throw new SessionError("pin_reset_used", 410, "Reset link already used");
  }
  if (result.status === "revoked") {
    throw new SessionError("pin_reset_revoked", 410, "Reset link revoked");
  }
  if (result.status === "expired") {
    throw new SessionError("pin_reset_expired", 410, "Reset link expired");
  }
  if (result.status === "portal_token_inactive") {
    throw new SessionError("pin_reset_portal_inactive", 410, "Portal link inactive");
  }
  if (result.status !== "valid" || !result.employee_name || !result.expires_at) {
    throw new SessionError("pin_reset_invalid", 404, "Invalid reset link");
  }

  return {
    valid: true,
    employee_name: result.employee_name,
    expires_at: result.expires_at,
  };
}

export async function consumePortalPinReset(
  secret: string,
  pin: string,
  confirmPin: string,
): Promise<{ employee_name: string }> {
  if (!isValidPortalPin(pin)) {
    throw new SessionError("invalid_pin", 400, "PIN must be 4-6 digits");
  }
  if (pin !== confirmPin) {
    throw new SessionError("pin_mismatch", 400, "PIN confirmation does not match");
  }

  const pinHash = await hashPortalPin(pin);
  const hashHex = await secretToHashHex(secret);
  const result = await consumeEmployeePortalPinReset(hashHex, pinHash);

  if (result.status === "used") {
    throw new SessionError("pin_reset_used", 410, "Reset link already used");
  }
  if (result.status === "revoked") {
    throw new SessionError("pin_reset_revoked", 410, "Reset link revoked");
  }
  if (result.status === "expired") {
    throw new SessionError("pin_reset_expired", 410, "Reset link expired");
  }
  if (result.status === "portal_token_inactive") {
    throw new SessionError("pin_reset_portal_inactive", 410, "Portal link inactive");
  }
  if (result.status === "invalid" || result.status !== "ok" || !result.token_id) {
    throw new SessionError("pin_reset_invalid", 404, "Invalid reset link");
  }

  await recordAccessLog({
    token_id: result.token_id,
    employee_id: result.employee_id!,
    tenant_id: result.tenant_id!,
    action: "pin_reset",
    http_status: 200,
  }).catch(() => undefined);

  return { employee_name: result.employee_name ?? "" };
}

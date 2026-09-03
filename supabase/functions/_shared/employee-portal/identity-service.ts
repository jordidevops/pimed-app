import { secretToHashHex } from "./bootstrap-service.ts";
import { documentIdLast4 } from "./identity-utils.ts";
import {
  clearEmployeePortalIdentityChallenge,
  confirmEmployeePortalIdentity,
  lookupTokenBySecret,
  recordAccessLog,
  verifyEmployeePortalIdentityDocument,
} from "./repository.ts";
import { SessionError } from "./session-service.ts";

export async function verifyPortalIdentity(
  secret: string,
  documentId: string,
): Promise<{ full_name: string }> {
  const tokenHashHex = await secretToHashHex(secret);
  const result = await verifyEmployeePortalIdentityDocument(tokenHashHex, documentId);

  if (result.status === "token_invalid") {
    throw new SessionError("token_invalid", 401);
  }

  if (result.status === "identity_not_configured") {
    throw new SessionError("identity_not_configured", 403, "Identity not configured");
  }

  if (result.status === "identity_locked") {
    const tokenId = result.token_id;
    const employeeId = result.employee_id;
    const tenantId = result.tenant_id;
    if (tokenId && employeeId && tenantId) {
      await recordAccessLog({
        token_id: tokenId,
        employee_id: employeeId,
        tenant_id: tenantId,
        action: "identity_verify_failed",
        http_status: 423,
        failure_reason: "identity_locked",
        metadata: {
          document_id_last4: documentIdLast4(documentId),
        },
      }).catch(() => undefined);
    }

    throw new SessionError(
      "identity_locked",
      423,
      "Identity verification locked",
      result.retry_after_seconds,
    );
  }

  if (result.status === "mismatch") {
    if (result.token_id && result.employee_id && result.tenant_id) {
      await recordAccessLog({
        token_id: result.token_id,
        employee_id: result.employee_id,
        tenant_id: result.tenant_id,
        action: "identity_verify_failed",
        http_status: 401,
        failure_reason: "document_mismatch",
        metadata: {
          document_id_last4: documentIdLast4(documentId),
        },
      }).catch(() => undefined);
    } else {
      const record = await lookupTokenBySecret(secret);
      if (record) {
        await recordAccessLog({
          token_id: record.token_id,
          employee_id: record.employee_id,
          tenant_id: record.tenant_id,
          action: "identity_verify_failed",
          http_status: 401,
          failure_reason: "document_mismatch",
          metadata: {
            document_id_last4: documentIdLast4(documentId),
          },
        }).catch(() => undefined);
      }
    }

    throw new SessionError("identity_mismatch", 401, "Document does not match");
  }

  if (result.status !== "match" || !result.full_name) {
    throw new SessionError("identity_mismatch", 401, "Document does not match");
  }

  return { full_name: result.full_name };
}

export async function confirmPortalIdentity(
  secret: string,
): Promise<{ next: "pin_setup" | "pin" | "ready"; full_name: string }> {
  const tokenHashHex = await secretToHashHex(secret);
  const result = await confirmEmployeePortalIdentity(tokenHashHex);

  if (result.status === "token_invalid") {
    throw new SessionError("token_invalid", 401);
  }

  if (result.status === "identity_not_configured") {
    throw new SessionError("identity_not_configured", 403, "Identity not configured");
  }

  if (result.status === "identity_challenge_required") {
    throw new SessionError("identity_challenge_required", 403, "Verify document first");
  }

  if (result.status !== "ok" || !result.next || !result.full_name) {
    throw new SessionError("token_invalid", 401);
  }

  if (result.token_id && result.employee_id && result.tenant_id) {
    await recordAccessLog({
      token_id: result.token_id,
      employee_id: result.employee_id,
      tenant_id: result.tenant_id,
      action: "identity_confirmed",
      http_status: 200,
    }).catch(() => undefined);
  }

  return {
    next: result.next,
    full_name: result.full_name,
  };
}

export async function rejectPortalIdentity(secret: string): Promise<void> {
  const record = await lookupTokenBySecret(secret);
  if (!record || !record.is_active || record.revoked_at) {
    throw new SessionError("token_invalid", 401);
  }

  const tokenHashHex = await secretToHashHex(secret);
  await clearEmployeePortalIdentityChallenge(tokenHashHex);

  await recordAccessLog({
    token_id: record.token_id,
    employee_id: record.employee_id,
    tenant_id: record.tenant_id,
    action: "identity_rejected",
    http_status: 200,
  }).catch(() => undefined);
}

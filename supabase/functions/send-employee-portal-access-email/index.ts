import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import {
  AccessEmailError,
  sendEmployeePortalAccessEmail,
} from "../_shared/employee-portal/access-email-service.ts";

const FEATURE = "send-employee-portal-access-email";

interface RequestBody {
  tenant_id?: string;
  employee_id?: string;
  token_id?: string;
  secret?: string;
  recipient?: string;
  locale?: string;
  template_id?: string | null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function jsonError(status: number, code: string, message?: string): Response {
  return json({ error: { code, message: message ?? code } }, status);
}

function parseBody(raw: unknown): RequestBody {
  if (!raw || typeof raw !== "object") throw new Error("invalid_body");
  return raw as RequestBody;
}

async function assertCanManageEmployee(
  userClient: ReturnType<typeof createUserClient>,
  employeeId: string,
): Promise<{ tenant_id: string; email: string | null }> {
  const { data, error } = await userClient
    .from("employees")
    .select("id, tenant_id, site_id, email")
    .eq("id", employeeId)
    .single();

  if (error || !data) throw new AccessEmailError("employee_not_found", 404);

  const { error: resolveError } = await userClient.rpc("resolve_public_site_for_employee", {
    p_employee_id: employeeId,
  });
  if (resolveError) {
    throw new AccessEmailError("unauthorized", 403, resolveError.message);
  }

  return { tenant_id: data.tenant_id, email: data.email };
}

Deno.serve(async (req) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonError(405, "method_not_allowed");
  }

  try {
    const tenantIdHeader = req.headers.get("x-tenant-id")?.trim();
    const userClient = createUserClient(req);

    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) {
      return jsonError(401, "invalid_auth");
    }

    const body = parseBody(await req.json());
    const tenantId = (body.tenant_id?.trim() || tenantIdHeader || "").trim();
    const employeeId = body.employee_id?.trim();
    const tokenId = body.token_id?.trim();
    const secret = body.secret?.trim();
    const recipientInput = body.recipient?.trim();

    if (!tenantId || !employeeId || !tokenId || !secret) {
      return jsonError(400, "missing_fields");
    }

    if (tenantIdHeader && tenantIdHeader !== tenantId) {
      return jsonError(403, "tenant_mismatch");
    }

    const employee = await assertCanManageEmployee(userClient, employeeId);
    if (employee.tenant_id !== tenantId) {
      return jsonError(403, "tenant_mismatch");
    }

    const defaultRecipient = employee.email?.trim().toLowerCase() ?? "";
    const recipient = (recipientInput || defaultRecipient).trim().toLowerCase();
    if (!recipient) {
      return jsonError(400, "missing_recipient");
    }

    const recipientOverride = Boolean(
      recipientInput && defaultRecipient && recipientInput.toLowerCase() !== defaultRecipient,
    );

    const result = await sendEmployeePortalAccessEmail({
      tenant_id: tenantId,
      employee_id: employeeId,
      token_id: tokenId,
      secret,
      recipient,
      recipient_override: recipientOverride,
      requested_by_user_id: authData.user.id,
      locale: body.locale ?? "ca",
      template_id: body.template_id ?? null,
    });

    return json({
      ok: true,
      email_log_id: result.email_log_id,
      portal_url: result.portal_url,
      recipient,
      recipient_override: recipientOverride,
    });
  } catch (err) {
    if (err instanceof AccessEmailError) {
      return jsonError(err.status, err.code, err.message);
    }
    const message = err instanceof Error ? err.message : "unknown_error";
    log("error", FEATURE, "Unhandled error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonError(500, "internal_error");
  }
});

/**
 * send-attendance-inspection-access-email — EX-09.2
 *
 * Authenticated Edge Function (verify_jwt = true). A manager/owner emails an
 * inspection access link to one or more recipients.
 *
 * Body: { link_id, secret, recipients: string[], locale? }
 *
 * Authorization: the caller must be able to manage inspection links for the
 * active tenant. We enforce this by calling the authenticated RPC
 * `list_attendance_inspection_access_links` with the user's JWT (RLS + role
 * check) and confirming the link belongs to that tenant. The secret is then
 * validated against the link via `peek_attendance_inspection_access`
 * (service_role) so we never email a forged secret.
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "send-attendance-inspection-access-email";

interface RequestBody {
  link_id?: string;
  secret?: string;
  recipients?: string[];
  locale?: string;
}

interface InspectionLinkRow {
  id: string;
  employee_id: string;
  employee_name: string;
  period_from: string;
  period_to: string;
  expires_at: string;
  revoked_at: string | null;
  is_active: boolean;
}

interface PeekRow {
  link_id: string;
  tenant_id: string;
  employee_id: string;
  period_from: string;
  period_to: string;
  expires_at: string;
  valid: boolean;
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

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function buildInspectionUrl(linkId: string, secret: string): string {
  const configured = Deno.env.get("PUBLIC_PORTAL_BASE_URL")?.trim();
  const systemDomain = Deno.env.get("PUBLIC_PORTAL_SYSTEM_DOMAIN")?.trim();
  const base = configured
    ? configured.replace(/\/$/, "")
    : systemDomain
      ? `https://${systemDomain.replace(/\/$/, "")}`
      : "http://localhost:3000";
  return `${base}/inspect/${linkId}?t=${encodeURIComponent(secret)}`;
}

function formatDate(value: string | null | undefined, locale: string): string {
  if (!value) return "";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return String(value);
  return parsed.toLocaleDateString(
    locale === "en" ? "en-GB" : locale === "es" ? "es-ES" : "ca-ES",
  );
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
    const userClient = createUserClient(req);
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) {
      return jsonError(401, "invalid_auth");
    }

    let body: RequestBody;
    try {
      body = (await req.json()) as RequestBody;
    } catch {
      return jsonError(400, "invalid_json");
    }

    const linkId = body.link_id?.trim() ?? "";
    const secret = body.secret?.trim() ?? "";
    const locale = body.locale?.trim() || "ca";
    const recipients = Array.isArray(body.recipients)
      ? body.recipients
          .map((r) => (typeof r === "string" ? r.trim().toLowerCase() : ""))
          .filter((r) => r.includes("@"))
      : [];

    if (!linkId || !isUuid(linkId) || !secret) {
      return jsonError(400, "missing_fields");
    }
    if (recipients.length === 0) {
      return jsonError(400, "missing_recipient");
    }

    // 1) Authorization: user must be able to see/manage this link for the active tenant.
    const { data: listData, error: listError } = await userClient.rpc(
      "list_attendance_inspection_access_links",
      { p_include_inactive: true },
    );
    if (listError) {
      return jsonError(403, "unauthorized", listError.message);
    }
    const links = ((listData as { links?: InspectionLinkRow[] } | null)?.links) ?? [];
    const link = links.find((l) => l.id === linkId);
    if (!link) {
      return jsonError(404, "link_not_found");
    }

    // 2) Validate the secret against the link (also fetches tenant scope).
    const admin = createAdminClient();
    const { data: peekData, error: peekError } = await admin.rpc(
      "peek_attendance_inspection_access",
      { p_link_id: linkId, p_secret: secret },
    );
    if (peekError) {
      return jsonError(500, "peek_failed", peekError.message);
    }
    if (!peekData) {
      // invalid secret / expired / revoked
      return jsonError(400, "link_invalid");
    }
    const peek = peekData as PeekRow;

    // 3) Gather email variables.
    const { data: tenant } = await admin
      .from("tenants")
      .select("name")
      .eq("id", peek.tenant_id)
      .maybeSingle();
    const tenantName = (tenant as { name?: string } | null)?.name ?? "";

    const { data: employee } = await admin
      .from("employees")
      .select("full_name, site_id")
      .eq("id", peek.employee_id)
      .maybeSingle();
    const employeeRow = employee as { full_name?: string; site_id?: string | null } | null;
    const employeeName = employeeRow?.full_name ?? link.employee_name ?? "";

    let supportEmail = "";
    if (employeeRow?.site_id) {
      const { data: site } = await admin
        .from("sites")
        .select("email_reply_to")
        .eq("id", employeeRow.site_id)
        .maybeSingle();
      supportEmail = (site as { email_reply_to?: string | null } | null)?.email_reply_to?.trim() ?? "";
    }

    const inspectionUrl = buildInspectionUrl(linkId, secret);

    const idempotencyKey = `attendance-inspection-access:${linkId}:${crypto.randomUUID()}`;
    const { data: emailLogId, error: enqueueError } = await admin.rpc("enqueue_email", {
      payload: {
        tenant_id: peek.tenant_id,
        site_id: employeeRow?.site_id ?? null,
        idempotency_key: idempotencyKey,
        to: recipients,
        event_type: "attendance.inspection_access",
        template_variables: {
          inspection_url: inspectionUrl,
          employee_name: employeeName,
          period_from: formatDate(peek.period_from, locale),
          period_to: formatDate(peek.period_to, locale),
          expires_at: formatDate(peek.expires_at, locale),
          tenant_name: tenantName,
          support_email: supportEmail,
        },
        locale,
        metadata: {
          link_id: linkId,
          employee_id: peek.employee_id,
          requested_by_user_id: authData.user.id,
          inspection_url: inspectionUrl,
        },
        tags: ["attendance", "inspection_access"],
      },
    });

    if (enqueueError || !emailLogId) {
      return jsonError(500, "enqueue_failed", enqueueError?.message);
    }

    return json({
      ok: true,
      email_log_id: emailLogId as string,
      inspection_url: inspectionUrl,
      recipients,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown_error";
    log("error", FEATURE, "Unhandled error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonError(500, "internal_error");
  }
});

import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { sha256Bytes, bytesToPostgresHex } from "../_shared/employee-portal/crypto.ts";
import { requireCustomerPortalBffAuth } from "../_shared/customer-portal/internal-auth.ts";
import { pickLocalePayload } from "../_shared/customer-portal/locale-payload.ts";
import { enrichResolveWithBulletinTitle } from "../_shared/customer-portal/bulletin-title.ts";

const FEATURE = "resolve-customer-report-share";
const HEX_64_RE = /^[0-9a-f]{64}$/;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "private, no-store",
      "X-Robots-Tag": "noindex, nofollow",
      "Referrer-Policy": "no-referrer",
    },
  });
}

/** Identical external shape for unknown / expired / revoked / kill-switch. */
function denied(): Response {
  return jsonResponse(404, { error: "not_found" });
}

function clientIp(req: Request): string | null {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0]?.trim() || null;
  return req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip");
}

Deno.serve(async (req: Request) => {
  initObservability();

  const unauthorized = await requireCustomerPortalBffAuth(req);
  if (unauthorized) return unauthorized;

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  let body: {
    token?: string;
    session_token?: string;
    staff_token?: string;
    report_version_id?: string;
    action?: string;
    request_id?: string;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "invalid_body" });
  }

  const ip = clientIp(req);
  const ua = req.headers.get("user-agent") ?? undefined;
  const admin = createAdminClient();
  // Never trust client-supplied audit ids (BFF belt).
  const auditRequestId = crypto.randomUUID();

  try {
    // Staff handoff secret → projection or account bulletin list
    if (body.staff_token) {
      if (!HEX_64_RE.test(body.staff_token)) {
        return denied();
      }
      const reportVersionId =
        typeof body.report_version_id === "string" && UUID_RE.test(body.report_version_id)
          ? body.report_version_id
          : null;

      const hash = bytesToPostgresHex(await sha256Bytes(body.staff_token));
      const { data, error } = await admin.rpc("exchange_customer_portal_staff_session", {
        p_token_hash: hash,
        p_ip_address: ip,
        p_user_agent: ua,
        p_report_version_id: reportVersionId,
      });

      if (error) {
        log("error", FEATURE, "staff exchange failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }

      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        return denied();
      }

      // Handoff consume: return opaque session only (no projection).
      if (row.consumed === true && typeof row.session_secret === "string") {
        return jsonResponse(200, {
          actor_type: "staff",
          session_token: row.session_secret,
          expires_at: row.expires_at,
          staff_user_id: row.staff_user_id,
          scope_mode: row.scope_mode,
          client_account_contact_id: row.client_account_contact_id,
          requires_report_version_id: row.requires_report_version_id,
          report_version_id: row.report_version_id,
          tenant_id: row.tenant_id,
          ...pickLocalePayload(row),
        });
      }

      const enriched = await enrichResolveWithBulletinTitle(admin, row);
      return jsonResponse(200, {
        actor_type: "staff",
        staff_user_id: enriched.staff_user_id,
        expires_at: enriched.expires_at,
        locale: enriched.locale,
        content_digest: enriched.content_digest,
        projection: enriched.projection,
        media_manifest: enriched.media_manifest,
        bulletins: enriched.bulletins,
        access_activity: enriched.access_activity,
        scope_mode: enriched.scope_mode,
        client_account_contact_id: enriched.client_account_contact_id,
        requires_report_version_id: enriched.requires_report_version_id,
        report_version_id: enriched.report_version_id,
        tenant_id: enriched.tenant_id,
        title: enriched.title,
        ...pickLocalePayload(enriched),
      });
    }

    // Exchange bearer share token → opaque session
    if (body.token) {
      if (!HEX_64_RE.test(body.token)) {
        return denied();
      }
      const hash = bytesToPostgresHex(await sha256Bytes(body.token));
      const { data, error } = await admin.rpc("exchange_customer_report_share_token", {
        p_token_hash: hash,
        p_session_ttl_minutes: 30,
        p_ip_address: ip,
        p_user_agent: ua,
        p_client_key: ip ?? "unknown",
      });

      if (error) {
        log("error", FEATURE, "exchange failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }

      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        if (row?.code === "rate_limited") {
          return jsonResponse(429, { error: "rate_limited" });
        }
        return denied();
      }

      const enriched = await enrichResolveWithBulletinTitle(admin, row);
      return jsonResponse(200, {
        session_token: enriched.session_secret,
        expires_at: enriched.expires_at,
        locale: enriched.locale,
        content_digest: enriched.content_digest,
        projection: enriched.projection,
        media_manifest: enriched.media_manifest,
        tenant_id: enriched.tenant_id,
        client_account_contact_id: enriched.client_account_contact_id,
        title: enriched.title,
        ...pickLocalePayload(enriched),
      });
    }

    // Revalidate opaque session
    if (body.session_token) {
      if (!HEX_64_RE.test(body.session_token)) {
        return denied();
      }
      const hash = bytesToPostgresHex(await sha256Bytes(body.session_token));
      const { data, error } = await admin.rpc("resolve_customer_portal_share_session", {
        p_session_token_hash: hash,
        p_action: body.action ?? "report_view",
        p_ip_address: ip,
        p_user_agent: ua,
        p_request_id: auditRequestId,
      });

      if (error) {
        log("error", FEATURE, "session resolve failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }

      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        return denied();
      }

      const enriched = await enrichResolveWithBulletinTitle(admin, row);
      return jsonResponse(200, {
        locale: enriched.locale,
        content_digest: enriched.content_digest,
        projection: enriched.projection,
        media_manifest: enriched.media_manifest,
        tenant_id: enriched.tenant_id,
        client_account_contact_id: enriched.client_account_contact_id,
        title: enriched.title,
        ...pickLocalePayload(enriched),
      });
    }

    return jsonResponse(400, { error: "token_or_session_required" });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});

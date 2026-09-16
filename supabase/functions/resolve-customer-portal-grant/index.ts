import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { sha256Bytes, bytesToPostgresHex } from "../_shared/employee-portal/crypto.ts";
import { requireCustomerPortalBffAuth } from "../_shared/customer-portal/internal-auth.ts";
import { pickLocalePayload } from "../_shared/customer-portal/locale-payload.ts";
import { enrichResolveWithBulletinTitle } from "../_shared/customer-portal/bulletin-title.ts";

const FEATURE = "resolve-customer-portal-grant";
const HEX_64_RE = /^[0-9a-f]{64}$/;

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

function denied(): Response {
  return jsonResponse(404, { error: "not_found" });
}

function clientIp(req: Request): string | null {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0]?.trim() || null;
  return req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip");
}

function normalizeEmail(raw: string): string {
  return raw.trim().toLowerCase();
}

function customerPortalOrigin(): string {
  const configured = Deno.env.get("CUSTOMER_PORTAL_ORIGIN")?.trim();
  if (!configured) {
    throw new Error("CUSTOMER_PORTAL_ORIGIN is required");
  }
  const origin = new URL(configured);
  if (origin.protocol !== "https:" && origin.protocol !== "http:") {
    throw new Error("CUSTOMER_PORTAL_ORIGIN must be http(s)");
  }
  return origin.origin;
}

function buildLoginHtml(loginUrl: string, expiresAt?: unknown): string {
  const expiresLine =
    typeof expiresAt === "string"
      ? `<p style="color:#666;font-size:14px">Aquest enllaç caduca el ${new Date(expiresAt).toLocaleString("ca-ES")}.</p>`
      : "";
  return `<!DOCTYPE html>
<html><body style="font-family:system-ui,sans-serif;line-height:1.5;color:#111">
  <p>Accedeix al portal del client.</p>
  <p><a href="${loginUrl}">Obrir el portal</a></p>
  ${expiresLine}
  <p style="color:#999;font-size:12px">Si no has demanat aquest correu, pots ignorar-lo.</p>
</body></html>`;
}

async function findOrCreateAuthUser(
  admin: ReturnType<typeof createAdminClient>,
  email: string,
): Promise<string | null> {
  const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email,
  });
  if (!linkErr && linkData.user?.id) {
    return linkData.user.id;
  }

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    app_metadata: { customer_portal: true },
  });
  if (createErr) {
    log("error", FEATURE, "findOrCreateAuthUser failed", {
      extra: { link: linkErr?.message, create: createErr.message },
    });
    return null;
  }
  return created.user?.id ?? null;
}

Deno.serve(async (req: Request) => {
  initObservability();

  const unauthorized = await requireCustomerPortalBffAuth(req);
  if (unauthorized) return unauthorized;

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  let body: {
    invitation_token?: string;
    login_email?: string;
    login_token?: string;
    session_token?: string;
    action?: string;
    report_version_id?: string;
    request_id?: string;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "invalid_body" });
  }
  if ("site_origin" in (body as Record<string, unknown>)) {
    return jsonResponse(400, { error: "unsupported_field" });
  }

  const ip = clientIp(req);
  const ua = req.headers.get("user-agent") ?? undefined;
  const admin = createAdminClient();
  const auditRequestId = crypto.randomUUID();

  try {
    // Accept invitation → opaque grant session (no JWT to browser)
    if (body.invitation_token) {
      if (!HEX_64_RE.test(body.invitation_token)) return denied();
      const hash = bytesToPostgresHex(await sha256Bytes(body.invitation_token));

      const { data: peek, error: peekErr } = await admin.rpc("peek_customer_access_invitation", {
        p_token_hash: hash,
      });
      if (peekErr) {
        log("error", FEATURE, "peek failed", { extra: { error: peekErr.message } });
        return jsonResponse(500, { error: "internal_error" });
      }
      const peekRow = peek as Record<string, unknown> | null;
      if (!peekRow || peekRow.ok !== true) return denied();

      const email = normalizeEmail(String(peekRow.email_normalized ?? ""));
      if (!email) return denied();

      const authUserId = await findOrCreateAuthUser(admin, email);
      if (!authUserId) return jsonResponse(500, { error: "internal_error" });

      const { data, error } = await admin.rpc("accept_customer_access_invitation", {
        p_token_hash: hash,
        p_auth_user_id: authUserId,
        p_ip_address: ip,
        p_user_agent: ua,
        p_session_ttl_minutes: 60,
        p_client_key: ip ?? "unknown",
      });

      if (error) {
        log("error", FEATURE, "accept failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }
      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        if (row?.code === "rate_limited") return jsonResponse(429, { error: "rate_limited" });
        return denied();
      }

      return jsonResponse(200, {
        actor_type: "grant",
        session_token: row.session_secret,
        expires_at: row.expires_at,
        grant_id: row.grant_id,
        tenant_id: row.tenant_id,
      });
    }

    // Request return-visit login (identical external response)
    if (body.login_email) {
      const email = normalizeEmail(body.login_email);
      if (!email || !email.includes("@")) {
        return jsonResponse(200, { ok: true });
      }

      const { data, error } = await admin.rpc("request_customer_portal_login_token", {
        p_email_normalized: email,
        p_ip_address: ip,
        p_client_key: ip ?? "unknown",
        p_ttl_minutes: 20,
      });

      if (error) {
        log("error", FEATURE, "login request failed", { extra: { error: error.message } });
        return jsonResponse(200, { ok: true });
      }

      const row = data as Record<string, unknown> | null;
      if (row?.code === "rate_limited") {
        return jsonResponse(200, { ok: true });
      }

      const tokens = Array.isArray(row?.tokens)
        ? (row!.tokens as Array<Record<string, unknown>>)
        : [];
      let origin: string;
      try {
        origin = customerPortalOrigin();
      } catch (error) {
        captureException(error, { feature: FEATURE });
        return jsonResponse(500, { error: "internal_error" });
      }

      for (const t of tokens) {
        const secret = typeof t.token_secret === "string" ? t.token_secret : null;
        const tenantId = typeof t.tenant_id === "string" ? t.tenant_id : null;
        const grantId = typeof t.grant_id === "string" ? t.grant_id : null;
        if (!secret || !tenantId) continue;

        const loginUrl = `${origin}/g/${secret}`;
        const idempotencyKey = `customer-portal-login:${grantId ?? "grant"}:${secret.slice(0, 16)}`;

        const { error: enqueueError } = await admin.rpc("enqueue_email", {
          payload: {
            tenant_id: tenantId,
            idempotency_key: idempotencyKey,
            to: [email],
            subject: "Accés al portal del client",
            html_body: buildLoginHtml(loginUrl, t.expires_at ?? row?.expires_at),
            text_body: `Accedeix al portal del client:\n${loginUrl}`,
            email_type: "transactional",
            tags: ["customer_portal", "login"],
            metadata: {
              grant_id: grantId,
              kind: "customer_portal_login",
            },
          },
        });

        if (enqueueError) {
          log("error", FEATURE, "login email enqueue failed", {
            tenantId,
            extra: { grant_id: grantId, error: enqueueError.message },
          });
        } else {
          log("info", FEATURE, "login email enqueued", {
            tenantId,
            extra: { grant_id: grantId },
          });
        }
      }

      return jsonResponse(200, { ok: true });
    }

    // Exchange login handoff → grant session
    if (body.login_token) {
      if (!HEX_64_RE.test(body.login_token)) return denied();
      const hash = bytesToPostgresHex(await sha256Bytes(body.login_token));
      const { data, error } = await admin.rpc("exchange_customer_portal_login_token", {
        p_token_hash: hash,
        p_ip_address: ip,
        p_user_agent: ua,
        p_session_ttl_minutes: 60,
        p_client_key: ip ?? "unknown",
      });
      if (error) {
        log("error", FEATURE, "login exchange failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }
      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) {
        if (row?.code === "rate_limited") return jsonResponse(429, { error: "rate_limited" });
        return denied();
      }
      return jsonResponse(200, {
        actor_type: "grant",
        session_token: row.session_secret,
        expires_at: row.expires_at,
        grant_id: row.grant_id,
        tenant_id: row.tenant_id,
      });
    }

    // Resolve grant session
    if (body.session_token) {
      if (!HEX_64_RE.test(body.session_token)) return denied();
      const hash = bytesToPostgresHex(await sha256Bytes(body.session_token));
      const { data, error } = await admin.rpc("resolve_customer_portal_grant_session", {
        p_session_token_hash: hash,
        p_action: body.action ?? "list_bulletins",
        p_report_version_id: body.report_version_id ?? null,
        p_ip_address: ip,
        p_user_agent: ua,
        p_request_id: auditRequestId,
      });
      if (error) {
        log("error", FEATURE, "session resolve failed", { extra: { error: error.message } });
        return jsonResponse(500, { error: "internal_error" });
      }
      const row = data as Record<string, unknown> | null;
      if (!row || row.ok !== true) return denied();

      const enriched = await enrichResolveWithBulletinTitle(admin, row);
      return jsonResponse(200, {
        actor_type: "grant",
        grant_id: enriched.grant_id,
        tenant_id: enriched.tenant_id,
        bulletins: enriched.bulletins,
        locale: enriched.locale,
        content_digest: enriched.content_digest,
        projection: enriched.projection,
        media_manifest: enriched.media_manifest,
        report_version_id: enriched.report_version_id,
        client_account_contact_id: enriched.client_account_contact_id,
        access_activity: enriched.access_activity,
        title: enriched.title,
        ...pickLocalePayload(enriched),
      });
    }

    return jsonResponse(400, { error: "action_required" });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});

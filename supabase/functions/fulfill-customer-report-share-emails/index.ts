/**
 * fulfill-customer-report-share-emails
 *
 * Claims pending customer_report_share_delivery_intents, creates the share
 * (secret once), enqueues email via api.enqueue_email (with tenant BCC),
 * and marks the intent sent/failed.
 *
 * Branching (P2):
 * - mark_only / already_enqueued → only mark sent (email already queued)
 * - secret present → enqueue then mark (never remint after enqueue success)
 *
 * Auth: service_role Bearer only (cron / worker).
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "fulfill-customer-report-share-emails";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const DEFAULT_LIMIT = 20;

function customerPortalOrigin(): string {
  return (
    Deno.env.get("CUSTOMER_PORTAL_ORIGIN") ||
    Deno.env.get("PUBLIC_CUSTOMER_PORTAL_ORIGIN") ||
    "http://localhost:3003"
  ).replace(/\/$/, "");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type ClaimRow = { id: string };

type FulfillRow = {
  intent_id?: string;
  share_id?: string;
  secret?: string;
  to_email?: string | null;
  tenant_id?: string;
  site_id?: string | null;
  project_id?: string;
  report_version_id?: string;
  idempotency_key?: string;
  bulletin_bcc_emails?: string[] | null;
  expires_at?: string;
  already_enqueued?: boolean;
  mark_only?: boolean;
};

function asBcc(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (typeof item !== "string") continue;
    const e = item.trim().toLowerCase();
    if (!e || seen.has(e)) continue;
    seen.add(e);
    out.push(e);
  }
  return out;
}

function buildShareHtml(shareUrl: string, expiresAt?: string): string {
  const expiresLine = expiresAt
    ? `<p style="color:#666;font-size:14px">Aquest enllaç caduca el ${new Date(expiresAt).toLocaleString("ca-ES")}.</p>`
    : "";
  return `<!DOCTYPE html>
<html><body style="font-family:system-ui,sans-serif;line-height:1.5;color:#111">
  <p>Tens un butlletí d'intervenció disponible.</p>
  <p><a href="${shareUrl}">Obrir el butlletí</a></p>
  ${expiresLine}
  <p style="color:#999;font-size:12px">Si no esperaves aquest correu, pots ignorar-lo.</p>
</body></html>`;
}

async function markSent(
  admin: ReturnType<typeof createAdminClient>,
  intentId: string,
  tenantId?: string,
  emailLogId?: unknown,
): Promise<void> {
  try {
    await admin.rpc("mark_customer_report_share_delivery_result", {
      p_intent_id: intentId,
      p_success: true,
    });
  } catch (markErr) {
    log("error", FEATURE, "mark success failed (share kept live if emailed)", {
      tenantId,
      correlationId: intentId,
      extra: {
        email_log_id: emailLogId,
        error: markErr instanceof Error ? markErr.message : "mark_failed",
      },
    });
  }
}

async function processIntent(
  admin: ReturnType<typeof createAdminClient>,
  intentId: string,
): Promise<"sent" | "failed"> {
  let fulfill: FulfillRow | null = null;
  try {
    const { data, error } = await admin.rpc(
      "fulfill_customer_report_share_delivery_intent",
      { p_intent_id: intentId },
    );
    if (error) throw new Error(error.message);
    fulfill = data as FulfillRow;
  } catch (err) {
    const message = err instanceof Error ? err.message : "fulfill_failed";
    log("error", FEATURE, "fulfill RPC failed", {
      correlationId: intentId,
      extra: { error: message },
    });
    await admin.rpc("mark_customer_report_share_delivery_result", {
      p_intent_id: intentId,
      p_success: false,
      p_failure_reason: message.slice(0, 500),
    });
    return "failed";
  }

  // Email already queued in a prior attempt — mark sent only, never remint.
  if (fulfill?.mark_only === true || fulfill?.already_enqueued === true) {
    await markSent(admin, intentId, fulfill.tenant_id);
    log("info", FEATURE, "Delivery intent mark-only after prior enqueue", {
      tenantId: fulfill.tenant_id,
      correlationId: intentId,
      extra: { share_id: fulfill.share_id },
    });
    return "sent";
  }

  const secret = fulfill?.secret?.trim();
  const toEmail = fulfill?.to_email?.trim().toLowerCase();
  const tenantId = fulfill?.tenant_id;

  if (!secret || !toEmail || !tenantId) {
    const reason = !toEmail ? "missing_to_email" : "missing_secret_or_tenant";
    log("error", FEATURE, "fulfill payload incomplete", {
      correlationId: intentId,
      extra: { reason },
    });
    await admin.rpc("mark_customer_report_share_delivery_result", {
      p_intent_id: intentId,
      p_success: false,
      p_failure_reason: reason,
    });
    return "failed";
  }

  const shareUrl = `${customerPortalOrigin()}/s/${secret}`;
  const bcc = asBcc(fulfill.bulletin_bcc_emails);
  const idempotencyKey =
    `crs-email:${fulfill.idempotency_key || intentId}:${fulfill.share_id || "share"}`;

  const payload: Record<string, unknown> = {
    tenant_id: tenantId,
    site_id: fulfill.site_id ?? null,
    idempotency_key: idempotencyKey,
    to: [toEmail],
    subject: "Butlletí d'intervenció",
    html_body: buildShareHtml(shareUrl, fulfill.expires_at),
    text_body: `Butlletí d'intervenció\n\nObre l'enllaç: ${shareUrl}`,
    email_type: "transactional",
    tags: ["customer_portal", "bulletin_share"],
    metadata: {
      intent_id: intentId,
      share_id: fulfill.share_id,
      project_id: fulfill.project_id,
      report_version_id: fulfill.report_version_id,
    },
  };
  if (bcc.length > 0) {
    payload.bcc = bcc;
  }

  const { data: emailLogId, error: enqueueError } = await admin.rpc("enqueue_email", {
    payload,
  });

  if (enqueueError || !emailLogId) {
    const msg = enqueueError?.message ?? "enqueue_failed";
    log("error", FEATURE, "enqueue_email failed", {
      tenantId,
      correlationId: intentId,
      extra: { error: msg },
    });
    await admin.rpc("mark_customer_report_share_delivery_result", {
      p_intent_id: intentId,
      p_success: false,
      p_failure_reason: msg.slice(0, 500),
    });
    return "failed";
  }

  // Email queued: never mark failed (would revoke the emailed share). Retry mark only.
  await markSent(admin, intentId, tenantId, emailLogId);

  log("info", FEATURE, "Delivery intent fulfilled", {
    tenantId,
    correlationId: intentId,
    extra: {
      share_id: fulfill.share_id,
      email_log_id: emailLogId,
      bcc_count: bcc.length,
    },
  });

  return "sent";
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: { code: "method_not_allowed" } }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    log("error", FEATURE, "Unauthorized batch request");
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let limit = DEFAULT_LIMIT;
  try {
    const body = await req.json().catch(() => ({}));
    if (body && typeof body === "object" && "limit" in body) {
      const n = Number((body as { limit?: unknown }).limit);
      if (Number.isFinite(n) && n > 0) limit = Math.min(Math.floor(n), 100);
    }
  } catch {
    // empty body is fine
  }

  const admin = createAdminClient();
  let claimed: ClaimRow[] = [];

  try {
    const { data, error } = await admin.rpc(
      "claim_customer_report_share_delivery_intents",
      { p_limit: limit },
    );
    if (error) {
      log("error", FEATURE, "claim RPC failed", { extra: { error: error.message } });
      captureException(error, { feature: FEATURE });
      return json({ error: { code: "claim_failed", message: error.message } }, 500);
    }
    claimed = (Array.isArray(data) ? data : []) as ClaimRow[];
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return json({ error: { code: "internal_error" } }, 500);
  }

  let sent = 0;
  let failed = 0;

  for (const row of claimed) {
    const id = row?.id;
    if (!id) continue;
    try {
      const result = await processIntent(admin, id);
      if (result === "sent") sent += 1;
      else failed += 1;
    } catch (err) {
      failed += 1;
      const message = err instanceof Error ? err.message : "unknown";
      log("error", FEATURE, "Unhandled intent error", {
        correlationId: id,
        extra: { error: message },
      });
      captureException(err, { feature: FEATURE, correlationId: id });
      try {
        await admin.rpc("mark_customer_report_share_delivery_result", {
          p_intent_id: id,
          p_success: false,
          p_failure_reason: message.slice(0, 500),
        });
      } catch {
        // best-effort
      }
    }
  }

  return json({
    ok: true,
    claimed: claimed.length,
    sent,
    failed,
  });
});

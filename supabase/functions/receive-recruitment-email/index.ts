/*
  Edge Function: receive-recruitment-email (REC-7)
  ────────────────────────────────────────────────
  Webhook públic per Resend Inbound → api.ingest_recruitment_inbound_email.

  MVP STATUS:
  - Function is ready (Svix verify + ingest RPC).
  - Production activation requires Resend Inbound + MX + secrets.
  - See docs/plans/recruitment/rec7-inbound-activation.md

  Env:
    RESEND_INBOUND_WEBHOOK_SECRET  (whsec_…) — preferred
    RESEND_WEBHOOK_SECRET          — fallback for local only
    SUPABASE_SERVICE_ROLE_KEY      — via createAdminClient

  Tenant resolution (MVP):
    Payload must include tenant_id (stub/tests), OR
    X-Tenant-Id header (manual wiring), OR
    data.to matching recruitment_settings.inbound_address_hint (best-effort).
    Full mailbox→tenant map is post-MVP.
*/
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "receive-recruitment-email";
const MAX_TIMESTAMP_DIFF_SECONDS = 300;

const RESEND_INBOUND_WEBHOOK_SECRET =
  Deno.env.get("RESEND_INBOUND_WEBHOOK_SECRET") ??
  Deno.env.get("RESEND_WEBHOOK_SECRET") ??
  "";

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function verifyWebhookSignature(
  rawBody: string,
  headers: Headers,
  secret: string,
): Promise<boolean> {
  const base64Secret = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  let secretBytes: Uint8Array;
  try {
    secretBytes = Uint8Array.from(atob(base64Secret), (c) => c.charCodeAt(0));
  } catch {
    log("error", FEATURE, "Webhook secret format invalid");
    return false;
  }

  const msgId = headers.get("svix-id");
  const msgTimestamp = headers.get("svix-timestamp");
  const msgSignature = headers.get("svix-signature");
  if (!msgId || !msgTimestamp || !msgSignature) {
    log("error", FEATURE, "Missing Svix headers");
    return false;
  }

  const tsSeconds = parseInt(msgTimestamp, 10);
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (isNaN(tsSeconds) || Math.abs(nowSeconds - tsSeconds) > MAX_TIMESTAMP_DIFF_SECONDS) {
    log("error", FEATURE, "Timestamp out of tolerance");
    return false;
  }

  const signedContent = `${msgId}.${msgTimestamp}.${rawBody}`;
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    secretBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBuffer = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(signedContent),
  );
  const computedSig = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));

  for (const sig of msgSignature.split(" ")) {
    const commaIdx = sig.indexOf(",");
    if (commaIdx === -1) continue;
    const version = sig.slice(0, commaIdx);
    const incoming = sig.slice(commaIdx + 1);
    if (version === "v1" && timingSafeEqual(incoming, computedSig)) {
      return true;
    }
  }
  log("error", FEATURE, "Invalid webhook signature");
  return false;
}

function jsonOk(body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function asRecord(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {};
}

function extractEmail(addr: unknown): { email: string | null; name: string | null } {
  if (typeof addr === "string") {
    const m = addr.match(/^(?:"?([^"<]*)"?\s*)?<?([^>\s]+@[^>\s]+)>?$/);
    if (m) {
      return { name: m[1]?.trim() || null, email: m[2].toLowerCase() };
    }
    return { email: addr.includes("@") ? addr.toLowerCase() : null, name: null };
  }
  const o = asRecord(addr);
  const email =
    typeof o.address === "string"
      ? o.address
      : typeof o.email === "string"
        ? o.email
        : null;
  const name = typeof o.name === "string" ? o.name : null;
  return { email: email?.toLowerCase() ?? null, name };
}

Deno.serve(async (req) => {
  initObservability();

  if (req.method !== "POST") {
    return errorResponse(405, "Method Not Allowed");
  }

  const rawBody = await req.text();

  if (!RESEND_INBOUND_WEBHOOK_SECRET) {
    log("error", FEATURE, "RESEND_INBOUND_WEBHOOK_SECRET not configured");
    return errorResponse(503, "Inbound webhook not configured — see rec7-inbound-activation.md");
  }

  const isValid = await verifyWebhookSignature(
    rawBody,
    req.headers,
    RESEND_INBOUND_WEBHOOK_SECRET,
  );
  if (!isValid) {
    return errorResponse(401, "Unauthorized — invalid signature");
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    return errorResponse(400, "Invalid JSON body");
  }

  const data = asRecord(payload.data ?? payload);
  const from = extractEmail(data.from ?? data.sender);
  const toRaw = data.to;
  const toList = Array.isArray(toRaw) ? toRaw : toRaw != null ? [toRaw] : [];
  const toEmails = toList
    .map((t) => extractEmail(t).email)
    .filter((e): e is string => Boolean(e));

  const subject = typeof data.subject === "string" ? data.subject : null;
  const bodyText =
    typeof data.text === "string"
      ? data.text
      : typeof data.body === "string"
        ? data.body
        : null;
  const bodyHtml = typeof data.html === "string" ? data.html : null;
  const resendId =
    typeof data.email_id === "string"
      ? data.email_id
      : typeof data.message_id === "string"
        ? data.message_id
        : typeof payload.id === "string"
          ? payload.id
          : null;

  if (!from.email) {
    return errorResponse(400, "from_email required");
  }

  const admin = createAdminClient();

  // Tenant resolution (MVP best-effort)
  let tenantId =
    (typeof data.tenant_id === "string" ? data.tenant_id : null) ??
    req.headers.get("x-tenant-id");

  if (!tenantId && toEmails.length > 0) {
    const { data: settingsRows } = await admin
      .from("recruitment_settings")
      .select("tenant_id, inbound_enabled, inbound_address_hint")
      .eq("inbound_enabled", true)
      .not("inbound_address_hint", "is", null)
      .limit(50);

    const match = (settingsRows ?? []).find((row) => {
      const hint = String(row.inbound_address_hint ?? "").toLowerCase().trim();
      return hint && toEmails.some((t) => t === hint || t.endsWith(`@${hint}`) || hint.includes(t));
    });
    tenantId = match?.tenant_id ?? null;
  }

  if (!tenantId) {
    log("warn", FEATURE, "Could not resolve tenant_id for inbound email", {
      extra: { toEmails, from: from.email },
    });
    return jsonOk({
      received: true,
      processed: false,
      reason: "tenant_unresolved — configure mailbox map (see rec7-inbound-activation.md)",
    });
  }

  const { data: settings, error: settingsErr } = await admin
    .from("recruitment_settings")
    .select("inbound_enabled")
    .eq("tenant_id", tenantId)
    .maybeSingle();

  if (settingsErr) {
    log("error", FEATURE, "Failed to load recruitment_settings", {
      extra: { tenantId, error: settingsErr.message },
    });
    return errorResponse(500, "settings_lookup_failed");
  }

  if (!settings?.inbound_enabled) {
    return jsonOk({
      received: true,
      processed: false,
      reason: "inbound_disabled_for_tenant",
      tenant_id: tenantId,
    });
  }

  const attachmentPaths: string[] = [];
  // Attachment download/upload to recruitment-cvs is post-MVP wiring;
  // paths can be filled when Resend attachment URLs are fetched with service role.

  const ingestPayload = {
    tenant_id: tenantId,
    from_email: from.email,
    from_name: from.name,
    subject,
    body_text: bodyText,
    body_html: bodyHtml,
    resend_email_id: resendId,
    received_at: new Date().toISOString(),
    attachment_paths: attachmentPaths,
    data_source_label: "email inbound",
  };

  const { data: result, error: rpcError } = await admin.rpc(
    "ingest_recruitment_inbound_email",
    { p_payload: ingestPayload },
  );

  if (rpcError) {
    log("error", FEATURE, "ingest_recruitment_inbound_email failed", {
      extra: { tenantId, error: rpcError.message },
    });
    return errorResponse(500, rpcError.message);
  }

  return jsonOk({
    received: true,
    processed: true,
    tenant_id: tenantId,
    result,
  });
});

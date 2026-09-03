/*
  Edge Function: resend-webhook
  ─────────────────────────────
  Endpoint públic (sense Bearer) que rep els webhooks de Resend i actualitza
  l'estat dels correus a data.email_logs via la RPC api.process_email_webhook.

  SEGURETAT: cada petició es verifica amb HMAC-SHA256 (estàndard Svix) usant
  el RESEND_WEBHOOK_SECRET configurat al Supabase Dashboard.

  Testeig local:
    supabase functions serve resend-webhook --env-file supabase/functions/.env.local
  Staging/prod: les variables s'han de guardar als Secrets del Vault de Supabase.
    supabase secrets set RESEND_WEBHOOK_SECRET=xxx --project-ref <ref>

  Resend envia els events via POST amb headers:
    svix-id: <uuid>
    svix-timestamp: <unix-seconds>
    svix-signature: v1,<base64-hmac>
*/
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "resend-webhook";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Tolerància de rellotge per prevenir atacs de reutilització (replay). */
const MAX_TIMESTAMP_DIFF_SECONDS = 300; // ±5 minuts

/**
 * Mapping d'events de Resend → estats interns.
 * Els events no inclosos aquí s'ignoren (però s'acusen com a rebuts).
 */
const EVENT_TO_STATUS: Record<string, string> = {
  "email.delivered":        "delivered",
  "email.bounced":          "bounced",
  "email.complained":       "complained",
  "email.suppressed":       "suppressed",
  "email.delivery_delayed": "processing",
};

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const RESEND_WEBHOOK_SECRET =
  Deno.env.get("RESEND_WEBHOOK_SECRET") ?? "";

// ---------------------------------------------------------------------------
// Svix signature verification (manual, sense dependència externa)
//
// Algoritme:
//   1. Parseig del secret: "whsec_<base64>" → bytes
//   2. Signed payload: "{svix-id}.{svix-timestamp}.{raw-body}"
//   3. HMAC-SHA256 amb els bytes del secret
//   4. Comparació constant-time contra les signatures rebudes ("v1,<base64>")
// ---------------------------------------------------------------------------

/**
 * Compara dues cadenes en temps constant per evitar timing attacks.
 * Equivalent a `crypto.timingSafeEqual` de Node.
 */
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
  // 1. Parseig del secret
  const base64Secret = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  let secretBytes: Uint8Array;
  try {
    secretBytes = Uint8Array.from(
      atob(base64Secret),
      (c) => c.charCodeAt(0),
    );
  } catch {
    log("error", FEATURE, "RESEND_WEBHOOK_SECRET format invalid");
    return false;
  }

  // 2. Llegir headers Svix
  const msgId        = headers.get("svix-id");
  const msgTimestamp = headers.get("svix-timestamp");
  const msgSignature = headers.get("svix-signature");

  if (!msgId || !msgTimestamp || !msgSignature) {
    log("error", FEATURE, "Missing Svix headers");
    return false;
  }

  // 3. Verificació del timestamp (anti-replay)
  const tsSeconds  = parseInt(msgTimestamp, 10);
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (isNaN(tsSeconds) || Math.abs(nowSeconds - tsSeconds) > MAX_TIMESTAMP_DIFF_SECONDS) {
    log("error", FEATURE, "Timestamp out of tolerance", {
      extra: { tsSeconds, nowSeconds },
    });
    return false;
  }

  // 4. Calcular signatura esperada
  const signedContent      = `${msgId}.${msgTimestamp}.${rawBody}`;
  const signedContentBytes = new TextEncoder().encode(signedContent);

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    secretBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBuffer  = await crypto.subtle.sign("HMAC", cryptoKey, signedContentBytes);
  const computedSig      = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));

  // 5. Comparar contra totes les signatures rebudes (Svix permet múltiples per rotació)
  //    Format: "v1,<base64> v1,<base64> ..."
  const signatures = msgSignature.split(" ");
  for (const sig of signatures) {
    const commaIdx = sig.indexOf(",");
    if (commaIdx === -1) continue;
    const version  = sig.slice(0, commaIdx);
    const incoming = sig.slice(commaIdx + 1);
    if (version === "v1" && timingSafeEqual(incoming, computedSig)) {
      return true;
    }
  }

  log("error", FEATURE, "Invalid webhook signature");
  return false;
}

// ---------------------------------------------------------------------------
// Helpers de resposta
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  initObservability();

  if (req.method !== "POST") {
    return errorResponse(405, "Method Not Allowed");
  }

  // Guardar el cos cru (necessari per la verificació HMAC)
  const rawBody = await req.text();

  // ── 1. Verificació de la signatura ──────────────────────────────────────
  if (!RESEND_WEBHOOK_SECRET) {
    log("error", FEATURE, "RESEND_WEBHOOK_SECRET not configured");
    return errorResponse(500, "Server misconfiguration");
  }

  const isValid = await verifyWebhookSignature(rawBody, req.headers, RESEND_WEBHOOK_SECRET);
  if (!isValid) {
    return errorResponse(401, "Unauthorized — invalid signature");
  }

  // ── 2. Parseig del payload ───────────────────────────────────────────────
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    return errorResponse(400, "Body JSON invàlid");
  }

  const eventType = typeof payload.type === "string" ? payload.type : undefined;
  const data      = (payload.data && typeof payload.data === "object" && !Array.isArray(payload.data))
    ? (payload.data as Record<string, unknown>)
    : {};
  const emailId   = typeof data.email_id === "string" ? data.email_id : undefined;

  // ── 3. Mapping event → estat intern ─────────────────────────────────────
  const newStatus = eventType ? EVENT_TO_STATUS[eventType] : undefined;

  if (!newStatus || !emailId) {
    log("info", FEATURE, "Event ignored", {
      extra: { eventType: eventType ?? "unknown", emailId: emailId ?? "missing" },
    });
    return jsonOk({ received: true, processed: false, reason: "event not mapped" });
  }

  // ── 4. Actualitzar estat via RPC ─────────────────────────────────────────
  const adminClient = createAdminClient();

  const rpcMetadata = {
    resend_event_type: eventType,
    resend_created_at: typeof payload.created_at === "string" ? payload.created_at : null,
    resend_data:       data,
    received_at:       new Date().toISOString(),
  };

  const { error: rpcError } = await adminClient.rpc("process_email_webhook", {
    p_provider_message_id: emailId,
    p_new_status:          newStatus,
    p_metadata:            rpcMetadata,
  });

  if (rpcError) {
    if (rpcError.message?.includes("LogNotFound")) {
      log("warn", FEATURE, "404 race condition — email log not found yet", {
        extra: { emailId, eventType },
      });
      return errorResponse(404, rpcError.message);
    }

    log("warn", FEATURE, "RPC process_email_webhook failed", {
      extra: { emailId, eventType, error: rpcError.message },
    });
    return jsonOk({
      received:  true,
      processed: false,
      email_id:  emailId,
      event:     eventType,
      error:     rpcError.message,
    });
  }

  if (newStatus === "bounced" || newStatus === "complained") {
    const { data: emailLog } = await adminClient
      .from("worker_email_logs")
      .select("id, tenant_id, site_id, subject")
      .eq("provider_message_id", emailId)
      .maybeSingle();

    if (emailLog?.tenant_id) {
      const operationLog = createOperationLogService(adminClient);
      await operationLog.log({
        tenantId: emailLog.tenant_id as string,
        siteId: (emailLog.site_id as string | null) ?? null,
        integrationType: "email",
        operationCode: "resend_delivery_webhook",
        status: "failed",
        title: newStatus === "bounced" ? "Email rebutjat (bounce)" : "Email marcat com a spam (complaint)",
        message: `Resend event: ${eventType}`,
        errorCode: newStatus,
        correlationId: emailLog.id as string,
        externalService: "resend",
        isRetryable: false,
        payloadSummary: {
          subject: (emailLog.subject as string | null)?.slice(0, 80) ?? null,
          resend_email_id: emailId,
        },
      });
    }
  }

  log("info", FEATURE, "Email status updated", {
    extra: { emailId, eventType, newStatus },
  });
  return jsonOk({ received: true, processed: true, email_id: emailId, new_status: newStatus });
});

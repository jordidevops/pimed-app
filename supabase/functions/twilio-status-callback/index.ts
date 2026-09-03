/**
 * twilio-status-callback
 *
 * Webhook Twilio per actualitzar estat de SMS/WhatsApp (delivery receipts).
 * verify_jwt = false — validació via signatura Twilio HMAC-SHA1.
 *
 * Estratègia de validació de signatura:
 *   1. Busca el delivery per MessageSid → obté tenant_id
 *   2. Llegeix l'auth_token del tenant via Vault (BYO)
 *   3. Si no hi ha delivery (o cap token), prova amb TWILIO_AUTH_TOKEN de plataforma
 *   4. Si no hi ha cap token configurat, accepta el callback (mode dev)
 *
 * Idempotència: la RPC complete_notification_delivery_by_provider_message és idempotent.
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { initObservability } from "../_shared/observability/system-error-tracker.ts";

const FEATURE = "twilio-status-callback";

initObservability({ feature: FEATURE });

async function computeTwilioSignature(url: string, body: string, authToken: string): Promise<string> {
  const params = new URLSearchParams(body);
  const sorted = [...params.entries()].sort(([a], [b]) => a.localeCompare(b));
  const data = url + sorted.map(([k, v]) => k + v).join("");

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(authToken),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );

  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

async function validateTwilioSignature(
  req: Request,
  body: string,
  authToken: string,
): Promise<boolean> {
  const signature = req.headers.get("X-Twilio-Signature");
  if (!signature) return false;

  try {
    const expected = await computeTwilioSignature(req.url, body, authToken);
    return expected === signature;
  } catch {
    return false;
  }
}

type TwilioCredentials = { auth_token?: string } | null;

async function resolveAuthToken(
  db: ReturnType<typeof createAdminClient>,
  messageSid: string,
): Promise<string | null> {
  // 1. Intenta trobar el tenant des de la delivery
  const { data: delivery } = await db
    .from("notification_deliveries")
    .select("tenant_id")
    .eq("provider_message_id", messageSid)
    .order("created_at", { ascending: false })
    .limit(1)
    .single();

  if (delivery?.tenant_id) {
    const { data: creds } = await db.rpc("get_tenant_twilio_credentials_service", {
      p_tenant_id: delivery.tenant_id,
    });
    const token = (creds as TwilioCredentials)?.auth_token;
    if (token) return token;
  }

  // 2. Fallback a token de plataforma (si n'hi ha)
  return Deno.env.get("TWILIO_AUTH_TOKEN") ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const body = await req.text();
  const params = new URLSearchParams(body);
  const messageSid = params.get("MessageSid") ?? params.get("SmsSid");
  const messageStatus = params.get("MessageStatus") ?? params.get("SmsStatus");

  if (!messageSid) {
    log("warn", FEATURE, "Missing MessageSid in callback", {});
    return new Response("Bad Request", { status: 400, headers: corsHeaders });
  }

  const db = createAdminClient();

  // Valida signatura si hi ha un token disponible
  const authToken = await resolveAuthToken(db, messageSid);
  if (authToken) {
    const valid = await validateTwilioSignature(req, body, authToken);
    if (!valid) {
      log("warn", FEATURE, "Invalid Twilio signature", { extra: { messageSid } });
      return new Response("Forbidden", { status: 403, headers: corsHeaders });
    }
  } else {
    log("warn", FEATURE, "No auth token available — skipping signature validation", {
      extra: { messageSid },
    });
  }

  if (messageSid && messageStatus) {
    const delivered = ["delivered", "read"].includes(messageStatus);
    const failed = ["failed", "undelivered"].includes(messageStatus);

    if (delivered || failed) {
      const { error } = await db.rpc("complete_notification_delivery_by_provider_message", {
        p_provider: "twilio",
        p_provider_message_id: messageSid,
        p_status: delivered ? "delivered" : "failed",
        p_error_code: failed ? messageStatus : null,
      });

      if (error) {
        log("warn", FEATURE, "Delivery update failed", {
          extra: { messageSid, error: error.message },
        });
      }
    }
  }

  return new Response(
    '<?xml version="1.0" encoding="UTF-8"?><Response></Response>',
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "text/xml" },
    },
  );
});

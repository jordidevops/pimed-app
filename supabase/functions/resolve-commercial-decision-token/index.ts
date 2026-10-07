/**
 * CF-28 F9: public resolve for commercial /sign with IP rate-limit.
 * PublicSignPage / CommercialDecisionPage must call this Edge, not PostgREST RPC.
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  initObservability,
  captureException,
} from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import {
  checkCommercialSignRateLimit,
  getClientIp,
  tokenMissKey,
} from "../_shared/commercial-sign-rate-limit.ts";

const FEATURE = "resolve-commercial-decision-token";
const RESOLVE_IP_MAX = 60;
const POLL_IP_MAX = 120;
const MISS_MAX = 20;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "private, no-store",
      "Referrer-Policy": "no-referrer",
    },
  });
}

Deno.serve(async (req) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  let body: { token?: string; mark_opened?: boolean };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (token.length < 32) {
    return json(404, { kind: "not_found" });
  }

  const markOpened = body.mark_opened !== false;
  const ip = getClientIp(req);
  const admin = createAdminClient();

  try {
    const ipGate = await checkCommercialSignRateLimit(
      admin,
      markOpened ? "commercial_sign_resolve_ip" : "commercial_sign_poll_ip",
      ip,
      markOpened ? RESOLVE_IP_MAX : POLL_IP_MAX,
      1,
    );
    if (!ipGate.ok) {
      log("warn", FEATURE, "resolve rate_limited ip", {
        extra: { code: ipGate.code },
      });
      return json(429, { error: "rate_limited", code: "rate_limited" });
    }

    const { data, error } = await admin.rpc("resolve_commercial_decision_token", {
      p_token: token,
      p_mark_opened: markOpened,
    });

    if (error) {
      log("error", FEATURE, "resolve rpc failed", {
        extra: { error: error.message },
      });
      return json(500, { error: "internal_error" });
    }

    const payload = (data ?? { kind: "not_found" }) as {
      kind?: string;
    };

    if (payload.kind !== "commercial_decision") {
      const missKey = await tokenMissKey(token);
      const missGate = await checkCommercialSignRateLimit(
        admin,
        "commercial_sign_token_miss",
        missKey,
        MISS_MAX,
        1,
      );
      if (!missGate.ok) {
        return json(429, { error: "rate_limited", code: "rate_limited" });
      }
      return json(200, payload.kind ? payload : { kind: "not_found" });
    }

    return json(200, payload as Record<string, unknown>);
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return json(500, { error: "internal_error" });
  }
});

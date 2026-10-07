/*
  Edge Function: process-commercial-decision-token
  Public /sign commercial decision accept (native stamp) or decline.
*/

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createAdminDataClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import {
  checkCommercialSignRateLimit,
  getClientIp,
} from "../_shared/commercial-sign-rate-limit.ts";

const FEATURE = "process-commercial-decision-token";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DECIDE_IP_MAX = 30;

type RequestBody = {
  token: string;
  action?: "accept" | "decline";
  signature_base64?: string;
  signer_name?: string | null;
  reason?: string | null;
  client_op_id?: string | null;
  ip_address?: string | null;
  user_agent?: string | null;
};

type NativeLink = {
  error?: string;
  session_id?: string;
  signing_token?: string;
  request_id?: string;
  token_id?: string;
  tenant_id?: string;
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const db = createAdminClient();
  let body: RequestBody;
  try {
    body = await req.json() as RequestBody;
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (!body.token) {
    return json(400, { error: "missing_token" });
  }

  const action = body.action ?? "accept";
  const ipAddress = body.ip_address ?? getClientIp(req);
  const userAgent = body.user_agent ?? req.headers.get("user-agent");
  const clientOpId = body.client_op_id ?? crypto.randomUUID();

  try {
    const decideGate = await checkCommercialSignRateLimit(
      db,
      "commercial_sign_decide_ip",
      ipAddress || "unknown",
      DECIDE_IP_MAX,
      1,
    );
    if (!decideGate.ok) {
      log("warn", FEATURE, "decide rate_limited", {
        extra: { code: decideGate.code },
      });
      return json(429, { error: "rate_limited", code: "rate_limited" });
    }

    if (action === "decline") {
      const { data: lookup } = await db.rpc("lookup_commercial_decision_native_session", {
        p_token: body.token,
      });
      const link = (lookup ?? null) as NativeLink | null;

      const { data, error } = await db.rpc("apply_commercial_decision_by_token", {
        p_token: body.token,
        p_outcome: "declined",
        p_evidence: {
          reason: body.reason ?? null,
          signer_name: body.signer_name ?? null,
          ip_address: ipAddress,
          user_agent: userAgent,
        },
        p_client_op_id: clientOpId,
      });
      if (error) {
        return json(409, { error: error.message });
      }

      if (link?.signing_token) {
        await db.rpc("decline_signing_session_public", {
          p_token: link.signing_token,
          p_reason: body.reason ?? null,
        }).catch(() => {});
      }

      return json(200, { success: true, result: data });
    }

    if (!body.signature_base64) {
      return json(400, { error: "missing_signature" });
    }

    const { data: lookup, error: lookupErr } = await db.rpc(
      "lookup_commercial_decision_native_session",
      { p_token: body.token },
    );
    if (lookupErr) {
      return json(500, { error: lookupErr.message });
    }
    const link = (lookup ?? null) as NativeLink | null;
    if (!link || link.error || !link.session_id || !link.token_id) {
      return json(409, { error: link?.error ?? "native_session_missing" });
    }

    await db.rpc("update_signing_session_service", {
      p_session_id: link.session_id,
      p_ip_address: ipAddress,
      p_user_agent: userAgent,
    }).catch(() => {});

    if (body.signer_name?.trim()) {
      await db
        .from("document_signing_sessions")
        .update({ signer_name: body.signer_name.trim() })
        .eq("id", link.session_id)
        .catch(() => {});
    }

    const stampRes = await fetch(`${SUPABASE_URL}/functions/v1/stamp-pdf-signatures`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
      body: JSON.stringify({
        session_id: link.session_id,
        client_signature_base64: body.signature_base64,
        ip_address: ipAddress,
        user_agent: userAgent,
      }),
    });

    if (!stampRes.ok) {
      const errText = await stampRes.text().catch(() => "");
      log("error", FEATURE, "Stamp failed", {
        tenantId: link.tenant_id,
        extra: { status: stampRes.status, body: errText.slice(0, 400) },
      });
      return json(502, { error: "stamp_failed" });
    }

    // Consume commercial access token; strangler trigger applies the open request.
    const dataDb = createAdminDataClient();
    await dataDb
      .from("commercial_decision_access_tokens")
      .update({ status: "consumed" })
      .eq("id", link.token_id)
      .eq("status", "active");

    const stampJson = await stampRes.json().catch(() => ({}));
    return json(200, {
      success: true,
      stamped: true,
      request_id: link.request_id,
      stamp: stampJson,
    });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return json(500, {
      error: err instanceof Error ? err.message : "internal_error",
    });
  }
});

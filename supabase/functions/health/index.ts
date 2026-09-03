/**
 * health — Edge Function de monitorització d'estat
 *
 * Endpoints:
 *   GET ?check=live  → runtime viu (200 sempre)
 *   GET ?check=ready → DB reachable + latència (200 ok / 503 fail)
 *   GET (default)    → mateix que ready (compatibilitat UptimeRobot existent)
 *
 * verify_jwt = false a config.toml
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "health";

const DB_LATENCY_THRESHOLD_MS = 3000;

function json(body: unknown, status = 200): Response {
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

  if (req.method !== "GET" && req.method !== "HEAD") {
    return json({ error: "Method not allowed" }, 405);
  }

  const url = new URL(req.url);
  const check = url.searchParams.get("check") ?? "ready";
  const timestamp = new Date().toISOString();

  if (check === "live") {
    return json({ status: "ok", check: "live", timestamp });
  }

  if (check !== "ready") {
    return json({ status: "error", message: "Unknown check parameter", timestamp }, 400);
  }

  try {
    const started = Date.now();
    const adminClient = createAdminClient();
    const { error: dbError } = await adminClient.rpc("ping");
    const dbLatencyMs = Date.now() - started;

    if (dbError) {
      log("error", FEATURE, "DB ping failed", {
        extra: { error: dbError.message, db_latency_ms: dbLatencyMs },
      });
      return json({
        status: "fail",
        check: "ready",
        db: "fail",
        db_latency_ms: dbLatencyMs,
        timestamp,
        error: dbError.message,
      }, 503);
    }

    const degraded = dbLatencyMs >= DB_LATENCY_THRESHOLD_MS;
    const status = degraded ? "degraded" : "ok";

    return json({
      status,
      check: "ready",
      db: "ok",
      db_latency_ms: dbLatencyMs,
      timestamp,
    }, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    log("error", FEATURE, "Ready check failed", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return json({
      status: "fail",
      check: "ready",
      db: "fail",
      timestamp,
      error: message,
    }, 503);
  }
});

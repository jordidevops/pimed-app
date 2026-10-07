/**
 * CF-28 F9: detect commercial decision inconsistencies (no auto-fix).
 * Auth: service role Bearer only.
 */
import { createAdminClient } from "../_shared/supabase.ts";
import {
  initObservability,
  captureException,
} from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "reconcile-commercial-decision-ops";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

initObservability();

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function requireServiceRole(req: Request): Response | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!SERVICE_ROLE_KEY || !token || token !== SERVICE_ROLE_KEY) {
    return jsonResponse(401, { error: "unauthorized" });
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }
  const denied = requireServiceRole(req);
  if (denied) return denied;

  let limit = 50;
  try {
    const body = (await req.json().catch(() => ({}))) as { limit?: number };
    if (typeof body.limit === "number" && Number.isFinite(body.limit)) {
      limit = Math.max(1, Math.min(200, Math.floor(body.limit)));
    }
  } catch {
    /* defaults */
  }

  const admin = createAdminClient();
  try {
    const { data, error } = await admin.rpc(
      "reconcile_commercial_decision_inconsistencies",
      { p_limit: limit },
    );
    if (error) {
      log("error", FEATURE, "reconcile failed", { extra: { error: error.message } });
      captureException(error, { feature: FEATURE });
      return jsonResponse(500, { error: "reconcile_failed" });
    }
    const row = (data ?? {}) as Record<string, unknown>;
    log("info", FEATURE, "reconcile done", {
      extra: { findings_count: row.findings_count },
    });
    return jsonResponse(200, row);
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});

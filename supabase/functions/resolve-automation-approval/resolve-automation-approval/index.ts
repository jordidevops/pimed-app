/**
 * resolve-automation-approval
 *
 * POST body: { approval_id, resolution: 'approved'|'rejected'|'reassigned', comment?, reassign_to_user_id? }
 * Authenticated (JWT d'usuari).
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "resolve-automation-approval";

initObservability();

type Resolution = 'approved' | 'rejected' | 'reassigned';

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "invalid_json" });
  }

  const { approval_id, resolution, comment, reassign_to_user_id } = body as {
    approval_id?: string;
    resolution?: Resolution;
    comment?: string;
    reassign_to_user_id?: string;
  };

  if (!approval_id || !resolution) {
    return jsonResponse(400, { error: "approval_id and resolution are required" });
  }

  if (!['approved', 'rejected', 'reassigned'].includes(resolution)) {
    return jsonResponse(400, { error: "resolution must be approved, rejected, or reassigned" });
  }

  const db = createUserClient(req);

  // Validate user session
  const { data: { user }, error: authError } = await db.auth.getUser();
  if (authError || !user) {
    return jsonResponse(401, { error: "unauthorized" });
  }

  try {
    const { error } = await db.rpc('resolve_automation_approval', {
      p_approval_id: approval_id,
      p_resolution: resolution,
      p_resolved_by_user_id: user.id,
      p_comment: comment ?? null,
      p_reassign_to_user_id: reassign_to_user_id ?? null,
    });

    if (error) {
      log('error', FEATURE, 'resolve_automation_approval RPC failed', {
        userId: user.id,
        extra: { approval_id, resolution, error: error.message },
      });
      return jsonResponse(500, { error: "rpc_failed", detail: error.message });
    }

    log('info', FEATURE, 'Approval resolved', {
      userId: user.id,
      extra: { approval_id, resolution },
    });

    return jsonResponse(200, { ok: true });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});

// =============================================================================
// resolve-automation-approval — Resolució d'aprovacions humanes
// =============================================================================
//
// Edge Function HTTP cridada per la UI quan un usuari aprova o rebutja
// una aprovació pendent d'un step d'automatització.
//
// SEGURETAT:
//   · Usa createUserClient: respecta RLS i el JWT de l'usuari.
//   · La RPC api.resolve_automation_approval valida:
//       - Que l'aprovació pertany al tenant actiu (x-tenant-id)
//       - Que l'usuari és l'assignat o té el rol assignat
//       - Que l'aprovació és en estat PENDING
//
// ENDPOINT:
//   POST /functions/v1/resolve-automation-approval
//   Headers: Authorization: Bearer <JWT>, x-tenant-id: <uuid>
//
// BODY:
//   { "approval_id": "<uuid>", "decision": "approved" | "rejected", "comment"?: "..." }
//
// RESPOSTA:
//   200: { "success": true, "decision": "approved"|"rejected", "next_step_id": "..." | null }
//   400: { "error": "validation_error", "message": "..." }
//   401: { "error": "unauthorized", "message": "..." }
//   404: { "error": "not_found", "message": "..." }
//   500: { "error": "internal_error", "message": "..." }
// =============================================================================

import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "resolve-automation-approval";

// ---------------------------------------------------------------------------
// Tipus
// ---------------------------------------------------------------------------

interface ResolveApprovalBody {
  approval_id: string;
  decision:    "approved" | "rejected";
  comment?:    string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, error: string, message: string): Response {
  return jsonResponse({ error, message }, status);
}

function parseBody(raw: unknown): ResolveApprovalBody {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("invalid_body");
  }

  const body = raw as Record<string, unknown>;

  if (!body.approval_id || typeof body.approval_id !== "string") {
    throw new Error("approval_id_required");
  }

  if (body.decision !== "approved" && body.decision !== "rejected") {
    throw new Error("decision_must_be_approved_or_rejected");
  }

  return {
    approval_id: body.approval_id,
    decision:    body.decision as "approved" | "rejected",
    comment:     typeof body.comment === "string" ? body.comment : undefined,
  };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Only POST is supported");
  }

  // Verificar tenant header
  const tenantId = req.headers.get("x-tenant-id");
  if (!tenantId) {
    return errorResponse(400, "missing_tenant", "Header x-tenant-id is required");
  }

  // Parsejar body
  let body: ResolveApprovalBody;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch (err) {
    const code = err instanceof Error ? err.message : "invalid_body";
    return errorResponse(400, "validation_error", code);
  }

  // Client d'usuari (respecta RLS i JWT)
  const userClient = createUserClient(req);

  // Verificar autenticació
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return errorResponse(401, "unauthorized", "Invalid or expired token");
  }

  log("info", FEATURE, "Resolving approval", {
    tenantId,
    userId:        user.id,
    correlationId: body.approval_id,
    extra: { decision: body.decision },
  });

  // Cridar la RPC
  const { data, error: rpcError } = await userClient.rpc(
    "resolve_automation_approval" as never,
    {
      p_approval_id: body.approval_id,
      p_decision:    body.decision,
      p_comment:     body.comment ?? null,
    } as never,
  );

  if (rpcError) {
    const msg     = rpcError.message ?? "";
    const details = (rpcError as { details?: string }).details ?? "";

    // Errors de negoci esperats (mapejar a 4xx)
    if (msg.includes("approval_not_found") || details.includes("P0002")) {
      return errorResponse(404, "not_found", "Approval not found or already resolved");
    }
    if (msg.includes("forbidden") || details.includes("P0003")) {
      return errorResponse(403, "forbidden", "Not authorized to resolve this approval");
    }
    if (msg.includes("invalid_decision") || details.includes("P0001")) {
      return errorResponse(400, "validation_error", msg);
    }

    // Error inesperat → capturar a Sentry
    captureException(rpcError, {
      feature: FEATURE,
      tags:    { tenant_id: tenantId, approval_id: body.approval_id },
      extra:   { rpcError, decision: body.decision },
    });

    log("error", FEATURE, "RPC resolve_automation_approval failed", {
      tenantId,
      userId:        user.id,
      correlationId: body.approval_id,
      extra: { error: msg },
    });

    return errorResponse(500, "internal_error", "Failed to resolve approval");
  }

  log("info", FEATURE, "Approval resolved", {
    tenantId,
    userId:        user.id,
    correlationId: body.approval_id,
    extra: { decision: body.decision, result: data },
  });

  return jsonResponse(data);
});

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { verifyProposalToken } from "../_shared/ai/tools/proposal-token.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "ai-chat-apply-proposal";

type ApplyBody = {
  proposalToken: string;
};

type ProposalLookup = {
  id: string;
  status: string;
  tool_name: string;
  payload: Record<string, unknown>;
};

Deno.serve(async (req: Request) => {
  initObservability();
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const tenantId = requireTenantHeader(req);
    const userClient = createUserClient(req);
    const user = await requireAuthenticatedUser(userClient);
    await assertTenantMember(userClient, tenantId, user.id);

    const body = (await req.json().catch(() => ({}))) as ApplyBody;
    const proposalToken = body.proposalToken?.trim();
    if (!proposalToken) {
      return errorResponse(400, "missing_token", "proposalToken és obligatori");
    }

    const verified = await verifyProposalToken(proposalToken);
    if (!verified.ok) {
      const status = verified.code === "PROPOSAL_EXPIRED" ? 410 : 403;
      return errorResponse(status, verified.code, verified.code === "PROPOSAL_EXPIRED"
        ? "La proposta ha expirat"
        : "Token de proposta invàlid");
    }

    if (verified.payload.tenantId !== tenantId) {
      return errorResponse(403, "PROPOSAL_INVALID", "Token no vàlid per a aquest tenant");
    }

    const adminClient = createAdminClient();

    const { data: lookupRaw, error: lookupError } = await adminClient.rpc(
      "lookup_ai_action_proposal_by_token_service",
      {
        p_proposal_token: proposalToken,
        p_tenant_id: tenantId,
      },
    );
    if (lookupError) throw new Error(lookupError.message);
    if (!lookupRaw) {
      return errorResponse(404, "PROPOSAL_NOT_FOUND", "Proposta no trobada");
    }

    const lookup = lookupRaw as ProposalLookup;
    if (lookup.id !== verified.payload.proposalId) {
      return errorResponse(403, "PROPOSAL_INVALID", "Token no coincideix amb la proposta");
    }

    if (lookup.tool_name === "propose_generate_document") {
      return errorResponse(
        410,
        "document_proposal_deprecated",
        "La generació de documents ja no s'aplica des del xat. Obre el generador de documents des de la targeta del missatge o torna a demanar-ho a l'assistent.",
      );
    }

    const { data: applied, error: applyError } = await adminClient.rpc(
      "apply_ai_action_proposal_service",
      {
        p_proposal_id: lookup.id,
        p_tenant_id: tenantId,
        p_user_id: user.id,
      },
    );
    if (applyError) {
      if (applyError.message.includes("forbidden")) {
        return errorResponse(403, "forbidden", "No tens permís per aplicar aquesta proposta");
      }
      throw new Error(applyError.message);
    }

    const result = applied as {
      status: string;
      applied_at?: string;
      tool_name?: string;
      result?: unknown;
    };

    return jsonResponse({
      status: result.status,
      appliedAt: result.applied_at ?? null,
      toolName: result.tool_name ?? null,
      result: result.result ?? null,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    const tenantId = req.headers.get("x-tenant-id");
    log("error", FEATURE, "Apply proposal failed", {
      tenantId: tenantId ?? undefined,
      extra: { error: message },
    });
    captureException(err, { feature: FEATURE, tenantId });

    if (tenantId) {
      try {
        const operationLog = createOperationLogService(createAdminClient());
        await operationLog.log({
          tenantId,
          integrationType: "ai_chat",
          operationCode: "apply_proposal",
          status: "failed",
          title: "Error aplicant proposta del xat IA",
          message: message.slice(0, 200),
          errorCode: "apply_proposal_failed",
          errorMessage: message,
          isRetryable: false,
        });
      } catch {
        // best-effort
      }
    }

    return errorResponse(500, "apply_proposal_failed", message);
  }
});

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { runAiGeneration } from "../_shared/ai/run.ts";
import { AiRateLimitError, AiUserBlockedError } from "../_shared/ai/usage.ts";
import type { AiGenerateRequestBody } from "../_shared/ai/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "generate-ai-content";

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

    const body = (await req.json().catch(() => ({}))) as AiGenerateRequestBody;
    if (!Array.isArray(body.messages) || body.messages.length === 0) {
      return errorResponse(400, "invalid_messages", "messages és obligatori");
    }

    const adminClient = createAdminClient();
    const result = await runAiGeneration({
      adminClient,
      tenantId,
      userId: user.id,
      body,
    });

    return jsonResponse({
      content: result.content,
      usage: result.usage,
      provider: result.provider,
      model: result.model,
      feature: body.feature ?? "generic",
      warnings: result.warnings ?? null,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    if (err instanceof AiRateLimitError) {
      return errorResponse(429, "rate_limit_exceeded", err.message, {
        hour_count: err.info.hour_count,
        day_count: err.info.day_count,
        hour_limit: err.info.hour_limit,
        day_limit: err.info.day_limit,
      });
    }
    if (err instanceof AiUserBlockedError) {
      return errorResponse(403, "user_blocked", err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Generation failed", {
      tenantId: req.headers.get("x-tenant-id") ?? undefined,
      extra: { error: message },
    });
    captureException(err, {
      feature: FEATURE,
      tenantId: req.headers.get("x-tenant-id"),
    });

    const tenantId = req.headers.get("x-tenant-id");
    if (tenantId) {
      try {
        const operationLog = createOperationLogService(createAdminClient());
        await operationLog.log({
          tenantId,
          integrationType: "ai_generation",
          operationCode: "generate_content",
          status: "failed",
          title: "Error generant contingut amb IA",
          message: message.slice(0, 200),
          errorCode: "generation_failed",
          errorMessage: message,
          externalService: "ai_provider",
          isRetryable: false,
        });
      } catch {
        // best-effort operation log
      }
    }

    return errorResponse(500, "generation_failed", message);
  }
});

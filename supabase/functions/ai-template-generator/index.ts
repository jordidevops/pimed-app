/*
  Edge Function: ai-template-generator
  Wrapper de generate-ai-content per al wizard de plantilles.
*/

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { extractFirstJsonObject } from "../_shared/ai/providers.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { runAiGeneration } from "../_shared/ai/run.ts";
import { AiRateLimitError, AiUserBlockedError } from "../_shared/ai/usage.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "ai-template-generator";

type AiTemplateRequestBody = {
  prompt: string;
  templateType?: "html" | "docx";
  provider?: string;
  model?: string;
  temperature?: number;
  maxTokens?: number;
};

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const body = (await req.json().catch(() => ({}))) as AiTemplateRequestBody;
    if (!body?.prompt || typeof body.prompt !== "string" || !body.prompt.trim()) {
      return errorResponse(400, "missing_prompt", "prompt és obligatori");
    }

    const tenantId = requireTenantHeader(req);
    const userClient = createUserClient(req);
    const user = await requireAuthenticatedUser(userClient);
    await assertTenantMember(userClient, tenantId, user.id);

    const adminClient = createAdminClient();
    const result = await runAiGeneration({
      adminClient,
      tenantId,
      userId: user.id,
      body: {
        feature: "template_generation",
        messages: [{ role: "user", content: body.prompt }],
        provider: body.provider as "openai" | "anthropic" | "gemini" | "openrouter" | undefined,
        model: body.model,
        temperature: body.temperature,
        maxTokens: body.maxTokens,
        responseFormat: "json",
      },
    });

    const parsed = extractFirstJsonObject(result.content);
    const jsonText = JSON.stringify(parsed, null, 2);

    return jsonResponse({
      jsonText,
      parsed,
      usage: result.usage,
      provider: result.provider,
      model: result.model,
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
    const tenantId = req.headers.get("x-tenant-id");
    log("error", FEATURE, "Template generation failed", {
      tenantId: tenantId ?? undefined,
      extra: { error: message },
    });
    captureException(err, { feature: FEATURE, tenantId });

    if (tenantId) {
      try {
        const operationLog = createOperationLogService(createAdminClient());
        await operationLog.log({
          tenantId,
          integrationType: "ai_generation",
          operationCode: "template_generation",
          status: "failed",
          title: "Error generant plantilla amb IA",
          message: message.slice(0, 200),
          errorCode: "generation_failed",
          errorMessage: message,
          externalService: "ai_provider",
          isRetryable: false,
        });
      } catch {
        // best-effort
      }
    }

    return errorResponse(500, "generation_failed", message);
  }
});

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { applyOverrides, generateWithProvider } from "../_shared/ai/providers.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { loadTenantAiRuntimeConfig } from "../_shared/ai/run.ts";
import { sanitizeProviderError } from "../_shared/ai/sanitize.ts";
import {
  AiGovernanceError,
  prepareAiExecution,
  toHttpGovernanceError,
} from "../_shared/ai/governance.ts";
import { logAiUsage } from "../_shared/ai/usage.ts";
import type { AiProvider } from "../_shared/ai/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "test-ai-connection";

type TestAiConnectionBody = {
  provider: AiProvider;
  model: string;
  systemPrompt?: string | null;
  temperature?: number;
  maxTokens?: number;
  userPrompt?: string;
  includeRaw?: boolean;
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

    const body = (await req.json().catch(() => ({}))) as TestAiConnectionBody;
    if (!body.provider || !body.model?.trim()) {
      return errorResponse(400, "invalid_body", "provider i model són obligatoris");
    }

    const userPrompt = (body.userPrompt?.trim() || "Prova");
    const adminClient = createAdminClient();
    const startedAt = Date.now();

    await prepareAiExecution(adminClient, {
      tenantId,
      userId: user.id,
      feature: "connection_test",
      provider: body.provider,
      model: body.model.trim(),
      estimatedTokens: body.maxTokens ?? 256,
    });

    const runtime = await loadTenantAiRuntimeConfig(adminClient, tenantId, body.provider);
    const config = applyOverrides(runtime, {
      provider: body.provider,
      model: body.model.trim(),
    });

    const temperature = body.temperature ?? config.temperature;
    const maxTokens = body.maxTokens ?? config.maxTokens;
    const systemText = body.systemPrompt?.trim() || config.systemPrompt || "";

    const messages = [
      ...(systemText ? [{ role: "system" as const, content: systemText }] : []),
      { role: "user" as const, content: userPrompt },
    ];

    let result;
    try {
      result = await generateWithProvider({
        config,
        messages,
        temperature,
        maxTokens,
        responseFormat: "text",
      });
    } catch (err) {
      const message = sanitizeProviderError(err instanceof Error ? err.message : String(err));
      await logAiUsage({
        adminClient,
        tenantId,
        userId: user.id,
        feature: "connection_test",
        provider: config.provider,
        model: config.model,
        requestStatus: "provider_error",
        latencyMs: Date.now() - startedAt,
        errorCode: message.slice(0, 200),
      });
      return errorResponse(502, "provider_error", message);
    }

    await logAiUsage({
      adminClient,
      tenantId,
      userId: user.id,
      feature: "connection_test",
      provider: result.provider,
      model: result.model,
      requestStatus: "success",
      promptTokens: result.usage.promptTokens,
      completionTokens: result.usage.completionTokens,
      latencyMs: Date.now() - startedAt,
    });

    return jsonResponse({
      request: {
        provider: body.provider,
        model: body.model.trim(),
        temperature,
        maxTokens,
        systemPrompt: systemText || null,
        userPrompt,
      },
      content: result.content,
      usage: result.usage,
      raw: body.includeRaw ? result : undefined,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    if (err instanceof AiGovernanceError) {
      const mapped = toHttpGovernanceError(err);
      return errorResponse(mapped.status, mapped.code, mapped.message);
    }
    const message = sanitizeProviderError(err instanceof Error ? err.message : String(err));
    log("error", FEATURE, "Connection test failed", {
      tenantId: req.headers.get("x-tenant-id") ?? undefined,
      extra: { error: message },
    });
    captureException(err, { feature: FEATURE, tenantId: req.headers.get("x-tenant-id") });
    return errorResponse(500, "test_failed", message);
  }
});

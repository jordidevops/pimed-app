import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  applyOverrides,
  generateWithProvider,
  mapRpcToRuntimeConfig,
} from "./providers.ts";
import {
  AiGovernanceError,
  prepareAiExecution,
} from "./governance.ts";
import {
  isModelNotFoundError,
  pickFallbackModel,
  syncTenantProviderModels,
} from "./models.ts";
import {
  AiRateLimitError,
  AiUserBlockedError,
  logAiUsage,
} from "./usage.ts";
import type {
  AiGenerateOverrides,
  AiGenerateRequestBody,
  AiGenerateResult,
  AiMessage,
  AiTenantRuntimeConfig,
} from "./types.ts";
import { toAiConfigError } from "./generationErrors.ts";
import {
  applyFeatureInstructions,
  loadFeaturePromptInstructions,
} from "./featurePrompts.ts";

function clampTemperature(value: number | null | undefined): number {
  if (!Number.isFinite(value ?? NaN)) return 0.2;
  return Math.max(0, Math.min(1, Number(value)));
}

function sanitizeMaxTokens(value: number | null | undefined): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 4096;
  const asInt = Math.floor(parsed);
  if (asInt < 1) return 1;
  if (asInt > 128000) return 128000;
  return asInt;
}

function sanitizeMessages(raw: AiGenerateRequestBody["messages"]): AiMessage[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((message): message is AiMessage => (
    !!message &&
    (message.role === "system" || message.role === "user" || message.role === "assistant" || message.role === "tool") &&
    typeof message.content === "string"
  ));
}

export async function loadTenantAiRuntimeConfig(
  adminClient: SupabaseClient,
  tenantId: string,
  providerOverride?: string | null,
): Promise<ReturnType<typeof mapRpcToRuntimeConfig>> {
  const { data, error } = await adminClient.rpc("get_ai_api_key_for_generation", {
    p_tenant_id: tenantId,
    p_provider: providerOverride ?? null,
  });

  if (error) throw toAiConfigError(error.message ?? "No s'ha pogut obtenir configuració AI");

  const raw = data as Record<string, unknown>;
  const provider = raw.provider as string | undefined;
  const apiKey = raw.api_key as string | undefined;
  const model = raw.model as string | undefined;
  const baseUrl = raw.base_url as string | undefined;

  if (!provider || !apiKey || !model || !baseUrl) {
    throw new Error("Configuració AI incompleta");
  }

  return mapRpcToRuntimeConfig(raw);
}

async function tryGenerate(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  temperature: number;
  maxTokens: number;
  responseFormat: "text" | "json";
}): Promise<AiGenerateResult> {
  return generateWithProvider(params);
}

export async function runAiGeneration(params: {
  adminClient: SupabaseClient;
  tenantId: string;
  userId: string;
  body: AiGenerateRequestBody;
}): Promise<AiGenerateResult> {
  const feature = params.body.feature ?? "generic";
  const startedAt = Date.now();

  const runtime = await loadTenantAiRuntimeConfig(
    params.adminClient,
    params.tenantId,
    params.body.provider ?? null,
  );

  const overrides: AiGenerateOverrides = {
    provider: params.body.provider,
    model: params.body.model,
  };

  const config = applyOverrides(runtime, overrides);
  const defaultTemperature = clampTemperature(config.temperature);
  const tenantMaxTokens = sanitizeMaxTokens(config.maxTokens);
  const requestTemperature = params.body.temperature == null
    ? defaultTemperature
    : clampTemperature(params.body.temperature);
  const requestMaxTokens = params.body.maxTokens == null
    ? tenantMaxTokens
    : sanitizeMaxTokens(params.body.maxTokens);
  const boundedMaxTokens = Math.min(requestMaxTokens, tenantMaxTokens);
  const featureInstructions = await loadFeaturePromptInstructions(
    params.adminClient,
    feature,
  );
  const messages = applyFeatureInstructions(
    sanitizeMessages(params.body.messages),
    featureInstructions,
  );
  if (!messages.some((m) => m.role === "user" && typeof m.content === "string" && m.content.trim())) {
    throw new Error("messages ha d'incloure almenys un missatge user");
  }

  let prepared;
  try {
    prepared = await prepareAiExecution(params.adminClient, {
      tenantId: params.tenantId,
      userId: params.userId,
      feature,
      provider: params.body.provider ?? null,
      model: params.body.model ?? null,
      estimatedTokens: 0,
    });
  } catch (err) {
    if (err instanceof AiGovernanceError) {
      const status = err.code === "AI_USER_BLOCKED" ? "blocked_user"
        : err.code === "AI_RATE_LIMIT" ? "blocked_rate_limit"
        : err.code === "AI_TOKENS_DAILY_LIMIT" ? "blocked_tokens_daily"
        : "blocked_governance";
      await logAiUsage({
        adminClient: params.adminClient,
        tenantId: params.tenantId,
        userId: params.userId,
        feature,
        provider: config.provider,
        model: config.model,
        requestStatus: status,
        latencyMs: Date.now() - startedAt,
        errorCode: err.code,
      });
      if (err.code === "AI_USER_BLOCKED") throw new AiUserBlockedError();
      if (err.code === "AI_RATE_LIMIT") {
        throw new AiRateLimitError(err.message, {
          allowed: false,
          hour_count: 0,
          day_count: 0,
          hour_limit: 0,
          day_limit: 0,
          warn_threshold_pct: 80,
          near_limit: true,
        });
      }
    }
    throw err;
  }

  if (prepared.model && prepared.model !== config.model) {
    config.model = prepared.model;
  }
  if (prepared.provider && prepared.provider !== config.provider) {
    config.provider = prepared.provider;
  }

  const rateInfo = prepared.rate as {
    near_limit?: boolean;
  } | undefined;
  const userWarnOnly = prepared.warnings.includes("warn_only_user");

  const generationConfig = { ...config };
  const generateParams = {
    messages,
    temperature: requestTemperature,
    maxTokens: boundedMaxTokens,
    responseFormat: params.body.responseFormat ?? "text" as const,
  };

  try {
    let result: AiGenerateResult;
    try {
      result = await tryGenerate({ config: generationConfig, ...generateParams });
    } catch (firstErr) {
      const firstMessage = firstErr instanceof Error ? firstErr.message : String(firstErr);
      if (!isModelNotFoundError(firstMessage)) throw firstErr;

      const models = await syncTenantProviderModels({
        adminClient: params.adminClient,
        tenantId: params.tenantId,
        provider: generationConfig.provider,
      });
      const fallback = pickFallbackModel(models, generationConfig.model);
      if (!fallback) throw firstErr;

      generationConfig.model = fallback;
      result = await tryGenerate({ config: generationConfig, ...generateParams });
    }

    await logAiUsage({
      adminClient: params.adminClient,
      tenantId: params.tenantId,
      userId: params.userId,
      feature,
      provider: result.provider,
      model: result.model,
      requestStatus: "success",
      promptTokens: result.usage.promptTokens,
      completionTokens: result.usage.completionTokens,
      latencyMs: Date.now() - startedAt,
    });

    return {
      ...result,
      warnings: {
        ...(rateInfo?.near_limit ? { near_limit: true } : {}),
        ...(userWarnOnly ? { warn_only_user: true } : {}),
      },
    };
  } catch (err) {
    if (!(err instanceof AiRateLimitError) && !(err instanceof AiUserBlockedError)) {
      const message = err instanceof Error ? err.message : String(err);
      await logAiUsage({
        adminClient: params.adminClient,
        tenantId: params.tenantId,
        userId: params.userId,
        feature,
        provider: generationConfig.provider,
        model: generationConfig.model,
        requestStatus: "provider_error",
        latencyMs: Date.now() - startedAt,
        errorCode: message.slice(0, 200),
      });
    }
    throw err;
  }
}

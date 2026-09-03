import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AiProvider } from "./types.ts";
import { log } from "../observability/structured-logger.ts";

const FEATURE = "ai-usage";

export type AiUserAccess = {
  configured: boolean;
  policy: "allow" | "warn_only" | "block";
  custom_hourly_limit: number | null;
  custom_daily_limit: number | null;
  blocked: boolean;
  warn_only: boolean;
};

export class AiUserBlockedError extends Error {
  constructor(message = "L'accés a la IA està bloquejat per a aquest usuari") {
    super(message);
    this.name = "AiUserBlockedError";
  }
}

export async function getAiUserAccess(
  adminClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<AiUserAccess> {
  const { data, error } = await adminClient.rpc("get_ai_user_access", {
    p_tenant_id: tenantId,
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);
  return data as AiUserAccess;
}

export type AiRateLimitInfo = {
  allowed: boolean;
  hour_count: number;
  day_count: number;
  hour_limit: number;
  day_limit: number;
  warn_threshold_pct: number;
  near_limit: boolean;
};

export class AiRateLimitError extends Error {
  constructor(
    message: string,
    public readonly info: AiRateLimitInfo,
  ) {
    super(message);
    this.name = "AiRateLimitError";
  }
}

export async function checkAndIncrementAiRateLimit(
  adminClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<AiRateLimitInfo> {
  const { data, error } = await adminClient.rpc("check_and_increment_ai_rate_limit", {
    p_tenant_id: tenantId,
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);

  const info = data as AiRateLimitInfo;
  if (!info.allowed) {
    throw new AiRateLimitError("Has superat el límit de crides IA", info);
  }
  return info;
}

export async function logAiUsage(params: {
  adminClient: SupabaseClient;
  tenantId: string;
  userId: string;
  feature: string;
  provider: AiProvider;
  model: string;
  requestStatus: string;
  promptTokens?: number | null;
  completionTokens?: number | null;
  latencyMs?: number | null;
  errorCode?: string | null;
}): Promise<void> {
  const { error } = await params.adminClient.rpc("log_ai_usage", {
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
    p_feature: params.feature,
    p_provider: params.provider,
    p_model: params.model,
    p_request_status: params.requestStatus,
    p_prompt_tokens: params.promptTokens ?? null,
    p_completion_tokens: params.completionTokens ?? null,
    p_latency_ms: params.latencyMs ?? null,
    p_error_code: params.errorCode ?? null,
  });
  if (error) {
    log("error", FEATURE, "log_ai_usage RPC error", {
      tenantId: params.tenantId,
      userId: params.userId,
      extra: { feature: params.feature, error: error.message },
    });
  }
}

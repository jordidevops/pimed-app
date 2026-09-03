import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AiProvider } from "./types.ts";
import { AiRateLimitError, AiUserBlockedError } from "./usage.ts";

export type PrepareAiExecutionResult = {
  allowed: boolean;
  provider: AiProvider;
  model: string;
  warnings: string[];
  rate?: Record<string, unknown>;
  tokens?: Record<string, unknown>;
};

export class AiGovernanceError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AiGovernanceError";
  }
}

function mapGovernanceError(message: string): AiGovernanceError {
  const code = message.includes("AI_") ? message.split(/\s/)[0] : "AI_GOVERNANCE_FAILED";
  if (code === "AI_USER_BLOCKED") {
    return new AiGovernanceError(code, "L'accés a la IA està bloquejat per a aquest usuari");
  }
  if (code === "AI_RATE_LIMIT") {
    return new AiGovernanceError(code, "Has superat el límit de crides IA");
  }
  if (code === "AI_TOKENS_DAILY_LIMIT") {
    return new AiGovernanceError(code, "Has superat el límit de tokens diari");
  }
  if (code === "AI_MODEL_NOT_ALLOWED") {
    return new AiGovernanceError(code, "Aquest model no està permès");
  }
  if (code === "AI_NOT_CONFIGURED") {
    return new AiGovernanceError(code, "La IA no està configurada per a aquest tenant");
  }
  return new AiGovernanceError(code, message);
}

export async function prepareAiExecution(
  adminClient: SupabaseClient,
  params: {
    tenantId: string;
    userId: string;
    siteId?: string | null;
    feature: string;
    provider?: AiProvider | null;
    model?: string | null;
    estimatedTokens?: number;
  },
): Promise<PrepareAiExecutionResult> {
  const { data, error } = await adminClient.rpc("prepare_ai_execution", {
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
    p_site_id: params.siteId ?? null,
    p_feature: params.feature,
    p_provider: params.provider ?? null,
    p_model: params.model ?? null,
    p_estimated_tokens: params.estimatedTokens ?? 0,
  });

  if (error) {
    throw mapGovernanceError(error.message);
  }

  const raw = data as Record<string, unknown>;
  return {
    allowed: Boolean(raw.allowed),
    provider: raw.provider as AiProvider,
    model: String(raw.model),
    warnings: Array.isArray(raw.warnings) ? raw.warnings.map(String) : [],
    rate: raw.rate as Record<string, unknown> | undefined,
    tokens: raw.tokens as Record<string, unknown> | undefined,
  };
}

export function toHttpGovernanceError(err: unknown): {
  status: number;
  code: string;
  message: string;
} {
  if (err instanceof AiGovernanceError) {
    const status = err.code === "AI_RATE_LIMIT" ? 429
      : err.code === "AI_USER_BLOCKED" ? 403
      : err.code === "AI_MODEL_NOT_ALLOWED" ? 400
      : 400;
    return { status, code: err.code.toLowerCase(), message: err.message };
  }
  if (err instanceof AiRateLimitError) {
    return { status: 429, code: "rate_limit_exceeded", message: err.message };
  }
  if (err instanceof AiUserBlockedError) {
    return { status: 403, code: "user_blocked", message: err.message };
  }
  const message = err instanceof Error ? err.message : String(err);
  return { status: 500, code: "governance_failed", message };
}

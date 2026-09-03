import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AiProvider } from "./types.ts";
import { normalizeProviderBaseUrl } from "./verify.ts";

const FETCH_TIMEOUT_MS = 15000;

async function fetchWithTimeout(input: string, init?: RequestInit): Promise<Response> {
  return fetch(input, {
    ...init,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
}

export function normalizeModelId(provider: AiProvider, raw: string): string {
  const trimmed = raw.trim();
  if (provider === "gemini") {
    return trimmed.replace(/^models\//, "");
  }
  return trimmed;
}

function filterOpenAiModels(ids: string[]): string[] {
  return ids.filter((id) =>
    /^(gpt-|o\d|chatgpt-)/i.test(id) &&
    !/embedding|whisper|tts|dall-e|moderation|transcribe|realtime|audio|image/i.test(id)
  );
}

function filterAnthropicModels(ids: string[]): string[] {
  return ids.filter((id) => /^claude/i.test(id));
}

function filterGeminiModels(entries: Array<{ name?: string; supportedGenerationMethods?: string[] }>): string[] {
  return entries
    .filter((entry) => {
      const methods = entry.supportedGenerationMethods ?? [];
      return methods.includes("generateContent");
    })
    .map((entry) => normalizeModelId("gemini", entry.name ?? ""))
    .filter(Boolean);
}

function filterOpenRouterModels(ids: string[]): string[] {
  return ids.filter((id) =>
    id.includes("/") &&
    !/embedding|whisper|tts|dall-e|moderation|image|audio|vision-only/i.test(id)
  );
}

export async function listProviderModels(params: {
  provider: AiProvider;
  apiKey: string;
  baseUrl?: string | null;
}): Promise<string[]> {
  const baseUrl = normalizeProviderBaseUrl({
    provider: params.provider,
    baseUrl: params.baseUrl,
  });

  if (params.provider === "openai" || params.provider === "openrouter") {
    const res = await fetchWithTimeout(`${baseUrl}/models`, {
      headers: { Authorization: `Bearer ${params.apiKey}` },
    });
    const data = await res.json().catch(() => ({} as { data?: Array<{ id?: string }> }));
    if (!res.ok) {
      const label = params.provider === "openrouter" ? "OpenRouter" : "OpenAI";
      throw new Error((data as { error?: { message?: string } })?.error?.message ?? `${label} models HTTP ${res.status}`);
    }
    const ids = (data.data ?? []).map((row) => row.id).filter((id): id is string => typeof id === "string");
    if (params.provider === "openrouter") {
      return filterOpenRouterModels(ids).sort();
    }
    return filterOpenAiModels(ids).sort();
  }

  if (params.provider === "anthropic") {
    const res = await fetchWithTimeout(`${baseUrl}/v1/models`, {
      headers: {
        "x-api-key": params.apiKey,
        "anthropic-version": "2023-06-01",
      },
    });
    const data = await res.json().catch(() => ({} as { data?: Array<{ id?: string }> }));
    if (!res.ok) {
      throw new Error((data as { error?: { message?: string } })?.error?.message ?? `Anthropic models HTTP ${res.status}`);
    }
    const ids = (data.data ?? []).map((row) => row.id).filter((id): id is string => typeof id === "string");
    return filterAnthropicModels(ids).sort();
  }

  const res = await fetchWithTimeout(`${baseUrl}/models`, {
    headers: { "x-goog-api-key": params.apiKey },
  });
  const data = await res.json().catch(() => ({} as { models?: Array<{ name?: string; supportedGenerationMethods?: string[] }> }));
  if (!res.ok) {
    throw new Error((data as { error?: { message?: string } })?.error?.message ?? `Gemini models HTTP ${res.status}`);
  }
  return filterGeminiModels(data.models ?? []).sort();
}

export function isModelNotFoundError(message: string): boolean {
  const lower = message.toLowerCase();
  return (
    lower.includes("model") && (
      lower.includes("not found") ||
      lower.includes("does not exist") ||
      lower.includes("not supported for generatecontent") ||
      lower.includes("invalid model")
    )
  );
}

export async function syncTenantProviderModels(params: {
  adminClient: SupabaseClient;
  tenantId: string;
  provider: AiProvider;
}): Promise<string[]> {
  const { data, error } = await params.adminClient.rpc("get_ai_api_key_for_generation", {
    p_tenant_id: params.tenantId,
    p_provider: params.provider,
  });
  if (error) throw new Error(error.message);

  const raw = data as Record<string, unknown>;
  const models = await listProviderModels({
    provider: params.provider,
    apiKey: String(raw.api_key ?? ""),
    baseUrl: String(raw.base_url ?? ""),
  });

  const { error: persistError } = await params.adminClient.rpc("persist_tenant_ai_provider_models", {
    p_tenant_id: params.tenantId,
    p_provider: params.provider,
    p_models: models,
  });
  if (persistError) throw new Error(persistError.message);

  return models;
}

export async function syncPlatformProviderModels(params: {
  adminClient: SupabaseClient;
  provider: AiProvider;
}): Promise<string[]> {
  const { data, error } = await params.adminClient.rpc("get_platform_ai_api_key_for_sync", {
    p_provider: params.provider,
  });
  if (error) throw new Error(error.message);

  const raw = data as Record<string, unknown>;
  const models = await listProviderModels({
    provider: params.provider,
    apiKey: String(raw.api_key ?? ""),
    baseUrl: String(raw.base_url ?? ""),
  });

  const { error: persistError } = await params.adminClient.rpc("persist_platform_ai_provider_models", {
    p_provider: params.provider,
    p_models: models,
  });
  if (persistError) throw new Error(persistError.message);

  return models;
}

export function pickFallbackModel(models: string[], current: string): string | null {
  if (models.includes(current)) return current;
  return models[0] ?? null;
}

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertPlatformAdmin,
  AuthError,
  requireAuthenticatedUser,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { syncPlatformProviderModels } from "../_shared/ai/models.ts";
import { normalizeProviderBaseUrl, verifyProviderApiKey } from "../_shared/ai/verify.ts";
import type { AiProvider } from "../_shared/ai/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "save-platform-api-key";

const VALID_PROVIDERS: AiProvider[] = ["openai", "anthropic", "gemini", "openrouter"];

type SaveBody = {
  provider?: string;
  apiKey?: string;
  model?: string | null;
  baseUrl?: string | null;
};

function parseProvider(value: string | undefined): AiProvider {
  const provider = (value ?? "").toLowerCase();
  if (!VALID_PROVIDERS.includes(provider as AiProvider)) {
    throw new AuthError(400, "invalid_provider", "Proveïdor no vàlid");
  }
  return provider as AiProvider;
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const userClient = createUserClient(req);
    await requireAuthenticatedUser(userClient);
    await assertPlatformAdmin(userClient, ["admin"]);

    const adminClient = createAdminClient();

    if (req.method === "DELETE") {
      const url = new URL(req.url);
      const provider = parseProvider(url.searchParams.get("provider") ?? undefined);

      const { error } = await adminClient.rpc("delete_platform_ai_provider_key", {
        p_provider: provider,
      });
      if (error) throw new Error(error.message);

      return jsonResponse({ success: true, deleted: true, provider });
    }

    if (req.method !== "POST") {
      return errorResponse(405, "method_not_allowed", "Només POST o DELETE");
    }

    const body = (await req.json().catch(() => ({}))) as SaveBody;
    const provider = parseProvider(body.provider);
    const apiKey = body.apiKey?.trim();
    const baseUrl = body.baseUrl?.trim() ? normalizeProviderBaseUrl({ provider, baseUrl: body.baseUrl }) : null;

    if (!apiKey) {
      return errorResponse(400, "api_key_required", "Cal introduir una API key");
    }

    try {
      await verifyProviderApiKey({ provider, apiKey, baseUrl });
    } catch (verifyErr) {
      const message = verifyErr instanceof Error ? verifyErr.message : String(verifyErr);
      await adminClient.rpc("record_platform_ai_key_verification_error", {
        p_provider: provider,
        p_error: message,
      });
      return errorResponse(422, "verification_failed", message);
    }

    const { data, error } = await adminClient.rpc("save_platform_ai_provider_secret", {
      p_provider: provider,
      p_api_key: apiKey,
      p_model: body.model?.trim() || null,
      p_base_url: baseUrl,
      p_available_models: null,
    });

    if (error) throw new Error(error.message);

    try {
      await syncPlatformProviderModels({ adminClient, provider });
    } catch (syncErr) {
      log("warn", FEATURE, "Model sync failed after save", {
        extra: { error: String(syncErr) },
      });
    }

    return jsonResponse({
      verified: true,
      provider,
      model: (data as { model?: string } | null)?.model ?? body.model ?? null,
      key_verified_at: (data as { key_verified_at?: string } | null)?.key_verified_at ?? null,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Save platform key failed", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return errorResponse(500, "internal_error", message);
  }
});

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertPlatformAdmin,
  AuthError,
  requireAuthenticatedUser,
} from "../_shared/ai/auth.ts";
import { syncPlatformProviderModels } from "../_shared/ai/models.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import type { AiProvider } from "../_shared/ai/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "refresh-platform-ai-models";

const VALID_PROVIDERS: AiProvider[] = ["openai", "anthropic", "gemini", "openrouter"];

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
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const userClient = createUserClient(req);
    await requireAuthenticatedUser(userClient);
    await assertPlatformAdmin(userClient, ["admin", "support"]);

    const body = (await req.json().catch(() => ({}))) as { provider?: string };
    const provider = parseProvider(body.provider);

    const adminClient = createAdminClient();
    const models = await syncPlatformProviderModels({ adminClient, provider });

    return jsonResponse({
      success: true,
      provider,
      models,
      count: models.length,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Platform model sync failed", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return errorResponse(500, "models_sync_failed", message);
  }
});

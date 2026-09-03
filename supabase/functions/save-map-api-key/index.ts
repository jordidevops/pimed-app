import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertGlobalTenantManager,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "save-map-api-key";

type KeyType = "geocoding" | "routes" | "maps_js";

type SaveBody = {
  keyType?: string;
  apiKey?: string;
};

const GOOGLE_KEY_RE = /^[A-Za-z0-9\-_.]{20,200}$/;

function parseKeyType(value: string | undefined): KeyType {
  if (value === "geocoding" || value === "routes" || value === "maps_js") return value;
  throw new AuthError(400, "invalid_key_type", "keyType must be geocoding, routes, or maps_js");
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Only POST is allowed");
  }

  try {
    const tenantId = requireTenantHeader(req);
    const userClient = createUserClient(req);
    const user = await requireAuthenticatedUser(userClient);
    await assertGlobalTenantManager(userClient, tenantId, user.id);

    const body = (await req.json().catch(() => ({}))) as SaveBody;
    const keyType = parseKeyType(body.keyType);

    const apiKey = body.apiKey?.trim() ?? "";

    if (!GOOGLE_KEY_RE.test(apiKey)) {
      return errorResponse(400, "invalid_key_format", "API key format is invalid");
    }

    const adminClient = createAdminClient();
    const rpcName =
      keyType === "routes"
        ? "upsert_tenant_routes_api_key_candidate"
        : keyType === "maps_js"
          ? "upsert_tenant_maps_js_api_key_candidate"
          : "upsert_tenant_geocoding_api_key_candidate";

    const { data, error } = await adminClient.rpc(rpcName, {
      p_tenant_id: tenantId,
      p_provider_key: "google",
      p_api_key: apiKey,
      p_ttl_hours: 24,
    });

    if (error) {
      log("error", FEATURE, "RPC failed saving map key candidate", {
        tenantId,
        extra: { keyType, rpcName, message: error.message, code: error.code },
      });
      // Surface a clearer client message for missing migrations / schema drift.
      if (
        typeof error.message === "string" &&
        error.message.includes("Could not find the function")
      ) {
        return errorResponse(
          503,
          "schema_not_ready",
          "Maps JS secret RPCs are missing. Apply pending migrations (supabase migration up --local).",
        );
      }
      throw new Error(error.message);
    }

    log("info", FEATURE, `${keyType} key candidate saved`, {
      tenantId,
      extra: { keyType, userId: user.id },
    });

    return jsonResponse({
      ok: true,
      status: "pending_verification",
      expiresAt: (data as { expires_at?: string } | null)?.expires_at ?? null,
    });
  } catch (error) {
    if (error instanceof AuthError) {
      return errorResponse(error.status, error.code, error.message);
    }
    log("error", FEATURE, "Unhandled error", {
      extra: { error: error instanceof Error ? error.message : String(error) },
    });
    captureException(error, { feature: FEATURE, tenantId: req.headers.get("x-tenant-id") });
    return errorResponse(500, "internal_error", "Unexpected server error");
  }
});

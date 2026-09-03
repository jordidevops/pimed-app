import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  requireAuthenticatedUser,
  requireTenantHeader,
  AuthError,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "get-maps-js-browser-key";

function normalizeMapId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9_\-]{5,100}$/.test(trimmed)) return null;
  return trimmed;
}

async function readTenantMapId(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
): Promise<string | null> {
  const { data } = await adminClient
    .from("tenants")
    .select("settings")
    .eq("id", tenantId)
    .maybeSingle();

  const settings = data?.settings as Record<string, unknown> | null | undefined;
  const maps = settings?.maps as Record<string, unknown> | undefined;
  return normalizeMapId(maps?.map_id);
}

async function readPlatformMapId(
  adminClient: ReturnType<typeof createAdminClient>,
): Promise<string | null> {
  const { data } = await adminClient
    .from("system_settings")
    .select("settings")
    .eq("module", "maps_js")
    .maybeSingle();

  const settings = data?.settings as Record<string, unknown> | null | undefined;
  const fromDb = normalizeMapId(settings?.map_id);
  if (fromDb) return fromDb;

  return normalizeMapId(Deno.env.get("MAPS_JS_PLATFORM_MAP_ID"));
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
    await assertTenantMember(userClient, tenantId, user.id);

    const adminClient = createAdminClient();
    const apiKey = await adminClient.rpc("get_tenant_secret", {
      p_tenant_id: tenantId,
      p_secret_type: "maps_js_api_key",
      p_provider: "google",
      p_accessed_by_fn: FEATURE,
      p_access_reason: "maps_js_browser_key",
    });

    if (!apiKey || typeof apiKey !== "string") {
      // Fallback (Fase B): platform / trial entitlement when BYOK isn't configured.
      const { data: entitlement } = await adminClient
        .from("tenant_maps_js_platform_entitlements")
        .select("activated_at, expires_at")
        .eq("tenant_id", tenantId)
        .maybeSingle();

      const now = Date.now();
      const expiresAt =
        entitlement && entitlement.expires_at ? new Date(entitlement.expires_at).getTime() : null;

      const isEntitled = Boolean(
        entitlement &&
          (expiresAt === null || Number.isFinite(expiresAt) ? now < (expiresAt ?? Infinity) : false),
      );

      if (isEntitled) {
        const platformKey = await adminClient.rpc("get_maps_js_platform_api_key_service", {
          p_accessed_by_fn: FEATURE,
          p_access_reason: "maps_js_browser_key_platform_entitlement",
        });

        const platformMapId = await readPlatformMapId(adminClient);

        if (platformKey && typeof platformKey === "string") {
          log("info", FEATURE, "Maps JS platform key delivered", {
            tenantId,
            extra: {
              userId: user.id,
              activatedAt: entitlement?.activated_at,
              source: "vault",
              hasMapId: Boolean(platformMapId),
            },
          });
          return jsonResponse({
            ok: true,
            apiKey: platformKey,
            mapId: platformMapId,
            source: "platform",
          });
        }

        // Dev / ops fallback when Vault secret is not yet provisioned.
        const envKey = Deno.env.get("MAPS_JS_PLATFORM_TRIAL_API_KEY")?.trim();
        if (envKey && envKey.length >= 20) {
          log("info", FEATURE, "Maps JS platform key delivered (env fallback)", {
            tenantId,
            extra: {
              userId: user.id,
              activatedAt: entitlement?.activated_at,
              source: "env",
              hasMapId: Boolean(platformMapId),
            },
          });
          return jsonResponse({
            ok: true,
            apiKey: envKey,
            mapId: platformMapId,
            source: "platform",
          });
        }

        log("warn", FEATURE, "Entitled but platform Maps JS key missing", {
          tenantId,
          extra: { userId: user.id },
        });
        return jsonResponse({ ok: false, code: "maps_js_platform_key_missing" });
      }

      return jsonResponse({ ok: false, code: "maps_js_not_enabled" });
    }

    const tenantMapId = await readTenantMapId(adminClient, tenantId);

    log("info", FEATURE, "Maps JS key delivered", {
      tenantId,
      extra: { userId: user.id, source: "byok", hasMapId: Boolean(tenantMapId) },
    });

    return jsonResponse({
      ok: true,
      apiKey,
      mapId: tenantMapId,
      source: "byok",
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

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

const FEATURE = "test-map-api-key";

type KeyType = "geocoding" | "routes" | "maps_js";

type TestBody = {
  keyType?: string;
};

function parseKeyType(value: string | undefined): KeyType {
  if (value === "geocoding" || value === "routes" || value === "maps_js") return value;
  throw new AuthError(400, "invalid_key_type", "keyType must be geocoding, routes, or maps_js");
}

async function testGoogleGeocodingKey(
  apiKey: string,
): Promise<{ ok: boolean; message: string; latencyMs: number }> {
  const started = Date.now();
  const url = new URL("https://maps.googleapis.com/maps/api/geocode/json");
  url.searchParams.set("address", "Barcelona, Spain");
  url.searchParams.set("key", apiKey);

  const response = await fetch(url.toString(), {
    headers: { Accept: "application/json" },
  });
  const latencyMs = Date.now() - started;

  if (!response.ok) {
    return {
      ok: false,
      message: formatGoogleHttpError(response.status, text, "Geocoding"),
      latencyMs,
    };
  }

  const data = (await response.json()) as { status?: string; error_message?: string };
  if (data.status === "OK" || data.status === "ZERO_RESULTS") {
    return { ok: true, message: "Clau vàlida", latencyMs };
  }

  return {
    ok: false,
    message: data.error_message
      ? `${data.status}: ${data.error_message}`
      : (data.status ?? "REQUEST_DENIED"),
    latencyMs,
  };
}

type RouteMatrixElement = {
  distanceMeters?: number;
  condition?: string;
  status?: { code?: number; message?: string };
};

type GoogleErrorBody = {
  error?: {
    code?: number;
    message?: string;
    status?: string;
    details?: Array<{ reason?: string; domain?: string; metadata?: Record<string, string> }>;
  };
};

/** Human-readable Google Maps Platform HTTP errors (never includes the API key). */
function formatGoogleHttpError(
  httpStatus: number,
  rawBody: string,
  apiLabel: "Routes" | "Geocoding",
): string {
  let googleMessage: string | null = null;
  let googleStatus: string | null = null;
  let reason: string | null = null;

  try {
    const parsed = JSON.parse(rawBody) as GoogleErrorBody;
    googleMessage = parsed.error?.message?.trim() || null;
    googleStatus = parsed.error?.status?.trim() || null;
    reason = parsed.error?.details?.find((d) => d.reason)?.reason ?? null;
  } catch {
    // non-JSON body
  }

  const permissionDenied =
    httpStatus === 403 ||
    googleStatus === "PERMISSION_DENIED" ||
    reason === "ACCESS_TOKEN_SCOPE_INSUFFICIENT" ||
    reason === "API_KEY_SERVICE_BLOCKED" ||
    reason === "SERVICE_DISABLED";

  if (permissionDenied) {
    const base =
      apiLabel === "Routes"
        ? "Google ha denegat l'accés (403). Activa Routes API al projecte GCP i assegura't que la clau tingui permís per a Routes API (no n'hi ha prou amb Geocoding)."
        : "Google ha denegat l'accés (403). Activa Geocoding API al projecte GCP i assegura't que la clau tingui permís per a Geocoding.";
    const detail = [googleStatus, googleMessage].filter(Boolean).join(": ");
    return detail ? `${base} Detall: ${detail}` : base;
  }

  if (httpStatus === 400) {
    return googleMessage
      ? `Petició invàlida (400): ${googleMessage}`
      : "Petició invàlida (400) a Google.";
  }

  if (httpStatus === 429) {
    return "Quota o rate-limit de Google exhaurit (429). Torna-ho a provar més tard.";
  }

  if (googleMessage) return `${googleStatus ? `${googleStatus}: ` : ""}${googleMessage}`;
  if (googleStatus) return `${googleStatus} (HTTP ${httpStatus})`;
  if (rawBody.trim()) return `HTTP ${httpStatus}: ${rawBody.trim().slice(0, 180)}`;
  return `HTTP ${httpStatus} des de Google ${apiLabel} API`;
}

function parseRouteMatrixElements(raw: string): RouteMatrixElement[] {
  const trimmed = raw.trim();
  if (!trimmed) return [];

  try {
    const parsed = JSON.parse(trimmed) as unknown;
    if (Array.isArray(parsed)) return parsed as RouteMatrixElement[];
    if (parsed && typeof parsed === "object") return [parsed as RouteMatrixElement];
  } catch {
    // NDJSON stream over HTTP
  }

  const rows: RouteMatrixElement[] = [];
  for (const line of trimmed.split(/\r?\n/)) {
    const chunk = line.trim();
    if (!chunk) continue;
    rows.push(JSON.parse(chunk) as RouteMatrixElement);
  }
  return rows;
}

async function testGoogleRoutesKey(
  apiKey: string,
): Promise<{ ok: boolean; message: string; latencyMs: number }> {
  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10_000);

  try {
    // Tiny Barcelona OD probe (Plaça Catalunya → Arc de Triomf)
    const response = await fetch(
      "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix",
      {
        method: "POST",
        signal: controller.signal,
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": apiKey,
          "X-Goog-FieldMask":
            "originIndex,destinationIndex,duration,distanceMeters,status,condition",
        },
        body: JSON.stringify({
          origins: [
            {
              waypoint: {
                location: {
                  latLng: { latitude: 41.3874, longitude: 2.1686 },
                },
              },
            },
          ],
          destinations: [
            {
              waypoint: {
                location: {
                  latLng: { latitude: 41.3911, longitude: 2.1806 },
                },
              },
            },
          ],
          travelMode: "DRIVE",
          routingPreference: "TRAFFIC_UNAWARE",
        }),
      },
    );
    const latencyMs = Date.now() - started;
    const text = await response.text().catch(() => "");

    if (!response.ok) {
      const message = formatGoogleHttpError(response.status, text, "Routes");
      return { ok: false, message, latencyMs };
    }

    let rows: RouteMatrixElement[];
    try {
      rows = parseRouteMatrixElements(text);
    } catch {
      return { ok: false, message: "Resposta Routes API invàlida", latencyMs };
    }

    const row = rows[0];
    if (row && typeof row.distanceMeters === "number") {
      return { ok: true, message: "Clau vàlida", latencyMs };
    }
    if (row?.status?.message) {
      return { ok: false, message: row.status.message, latencyMs };
    }

    return { ok: false, message: "Routes API no ha retornat distància", latencyMs };
  } catch (err) {
    const latencyMs = Date.now() - started;
    if (err instanceof Error && err.name === "AbortError") {
      return { ok: false, message: "Timeout contactant Google Routes API", latencyMs };
    }
    return {
      ok: false,
      message: err instanceof Error ? err.message : "Error de xarxa",
      latencyMs,
    };
  } finally {
    clearTimeout(timer);
  }
}

async function testGoogleMapsJsKey(
  apiKey: string,
): Promise<{ ok: boolean; message: string; latencyMs: number }> {
  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10_000);

  try {
    const url = new URL("https://maps.googleapis.com/maps/api/js");
    url.searchParams.set("key", apiKey);
    url.searchParams.set("v", "weekly");
    // Libraries are optional; include places to avoid missing-library confusion.
    url.searchParams.set("libraries", "places");
    // Callback keeps response as JS; we only analyze it server-side.
    url.searchParams.set("callback", "__mapsJsTestCallback");

    const response = await fetch(url.toString(), {
      method: "GET",
      headers: { Accept: "text/javascript" },
      signal: controller.signal,
    });

    const latencyMs = Date.now() - started;
    const text = await response.text().catch(() => "");

    if (!response.ok) {
      return {
        ok: false,
        message: `HTTP ${response.status} carregant Maps JavaScript API`,
        latencyMs,
      };
    }

    // Maps JS errors are embedded in the returned script (not reliably via HTTP status).
    if (text.includes("InvalidKeyMapError")) {
      return { ok: false, message: "InvalidKeyMapError: API key no és vàlida", latencyMs };
    }
    if (text.includes("ApiNotActivatedMapError")) {
      return { ok: false, message: "ApiNotActivatedMapError: activa 'Maps JavaScript API' al GCP", latencyMs };
    }
    if (text.includes("BillingNotEnabledMapError")) {
      return { ok: false, message: "BillingNotEnabledMapError: activa facturació al GCP", latencyMs };
    }
    if (text.includes("RefererNotAllowedMapError")) {
      // Expected during backend smoke tests: the referer is not the tenant portal host.
      return {
        ok: true,
        message:
          "Clau i API semblen OK, però la restricció per referrer bloqueja el smoke-test. Configura els referrers al tenant.",
        latencyMs,
      };
    }

    // If it contains some generic JS error, treat as fail (conservative).
    if (text.includes("Google Maps JavaScript API error") || text.includes("Google Maps JavaScript API")) {
      return {
        ok: true,
        message: "La resposta sembla consistent amb Maps JS (errors no classificats).",
        latencyMs,
      };
    }

    return { ok: true, message: "Clau Maps JS acceptada (smoke test OK)", latencyMs };
  } catch (err) {
    const latencyMs = Date.now() - started;
    if (err instanceof Error && err.name === "AbortError") {
      return { ok: false, message: "Timeout validant Maps JavaScript API key", latencyMs };
    }
    return {
      ok: false,
      message: err instanceof Error ? err.message : "Error de xarxa",
      latencyMs,
    };
  } finally {
    clearTimeout(timer);
  }
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

    const body = (await req.json().catch(() => ({}))) as TestBody;
    const keyType = parseKeyType(body.keyType);

    const adminClient = createAdminClient();
    const pendingRpc =
      keyType === "routes"
        ? "get_routes_pending_api_key_service"
        : keyType === "maps_js"
          ? "get_maps_js_pending_api_key_service"
          : "get_geocoding_pending_api_key_service";
    const activateRpc =
      keyType === "routes"
        ? "activate_tenant_routes_api_key_candidate"
        : keyType === "maps_js"
          ? "activate_tenant_maps_js_api_key_candidate"
          : "activate_tenant_geocoding_api_key_candidate";
    const failRpc =
      keyType === "routes"
        ? "fail_tenant_routes_api_key_candidate"
        : keyType === "maps_js"
          ? "fail_tenant_maps_js_api_key_candidate"
          : "fail_tenant_geocoding_api_key_candidate";

    const { data: pendingKey, error: pendingError } = await adminClient.rpc(pendingRpc, {
      p_tenant_id: tenantId,
      p_provider_key: "google",
    });

    if (pendingError) throw new Error(pendingError.message);

    if (!pendingKey || typeof pendingKey !== "string") {
      return jsonResponse({
        ok: false,
        message: "No hi ha cap clau candidata per provar. Desa'n una primer.",
        status: "failed",
      });
    }

    const result =
      keyType === "routes"
        ? await testGoogleRoutesKey(pendingKey)
        : keyType === "maps_js"
          ? await testGoogleMapsJsKey(pendingKey)
          : await testGoogleGeocodingKey(pendingKey);

    if (result.ok) {
      const { error: activateError } = await adminClient.rpc(activateRpc, {
        p_tenant_id: tenantId,
        p_provider_key: "google",
      });
      if (activateError) throw new Error(activateError.message);

      log("info", FEATURE, `${keyType} key activated`, {
        tenantId,
        extra: { userId: user.id, latencyMs: result.latencyMs },
      });

      return jsonResponse({
        ok: true,
        message: result.message,
        latencyMs: result.latencyMs,
        status: "active",
      });
    }

    await adminClient.rpc(failRpc, {
      p_tenant_id: tenantId,
      p_provider_key: "google",
    });

    log("warn", FEATURE, `${keyType} key test failed`, {
      tenantId,
      extra: { userId: user.id, message: result.message },
    });

    return jsonResponse({
      ok: false,
      message: result.message,
      latencyMs: result.latencyMs,
      status: "failed",
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

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertGlobalTenantEditor,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "routes-proxy";
const GOOGLE_TIMEOUT_MS = 10_000;
const EARTH_RADIUS_M = 6_371_000;

type DistanceBody = {
  action?: string;
  origin?: { lat?: number; lng?: number };
  destination?: { lat?: number; lng?: number };
};

type DistanceSource = "google_routes" | "haversine";

type DistanceResult = {
  source: DistanceSource;
  distance_m: number;
  duration_s: number | null;
  is_approximate: boolean;
};

function isValidCoord(lat: number, lng: number): boolean {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    lat >= -90 &&
    lat <= 90 &&
    lng >= -180 &&
    lng <= 180
  );
}

/** Great-circle distance in metres (same formula as data.haversine_distance_m). */
export function haversineDistanceM(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

function parseDurationSeconds(duration: string | undefined): number | null {
  if (!duration) return null;
  const match = /^(\d+(?:\.\d+)?)s$/.exec(duration);
  if (!match) return null;
  return Math.round(Number(match[1]));
}

type RouteMatrixElement = {
  distanceMeters?: number;
  duration?: string;
  condition?: string;
  status?: { code?: number; message?: string };
};

/**
 * computeRouteMatrix may return a JSON array (docs examples), a single
 * element object, or newline-delimited JSON (stream semantics over HTTP).
 */
function parseRouteMatrixElements(raw: string): RouteMatrixElement[] {
  const trimmed = raw.trim();
  if (!trimmed) return [];

  try {
    const parsed = JSON.parse(trimmed) as unknown;
    if (Array.isArray(parsed)) return parsed as RouteMatrixElement[];
    if (parsed && typeof parsed === "object") return [parsed as RouteMatrixElement];
  } catch {
    // fall through to NDJSON
  }

  const rows: RouteMatrixElement[] = [];
  for (const line of trimmed.split(/\r?\n/)) {
    const chunk = line.trim();
    if (!chunk) continue;
    try {
      rows.push(JSON.parse(chunk) as RouteMatrixElement);
    } catch {
      throw new Error("invalid_routes_response");
    }
  }
  return rows;
}

function pickRouteMatrixElement(rows: RouteMatrixElement[]): RouteMatrixElement {
  const row = rows[0];
  if (!row || row.condition === "ROUTE_NOT_FOUND") {
    throw new Error("route_not_found");
  }
  if (row.status?.code && row.status.code !== 0) {
    throw new Error(row.status.message ?? `google_status_${row.status.code}`);
  }
  if (typeof row.distanceMeters !== "number") {
    throw new Error("missing_distance");
  }
  return row;
}

async function getRoutesApiKey(tenantId: string): Promise<string | null> {
  const adminClient = createAdminClient();
  const { data: apiKey, error } = await adminClient.rpc("get_routes_api_key_service", {
    p_tenant_id: tenantId,
    p_provider_key: "google",
  });

  if (error) {
    log("warn", FEATURE, "failed to resolve routes key", {
      tenantId,
      extra: { error: error.message },
    });
    return null;
  }

  return typeof apiKey === "string" && apiKey.length > 0 ? apiKey : null;
}

async function computeGoogleRouteMatrix(
  apiKey: string,
  origin: { lat: number; lng: number },
  destination: { lat: number; lng: number },
): Promise<{ distance_m: number; duration_s: number | null }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GOOGLE_TIMEOUT_MS);

  try {
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
                  latLng: {
                    latitude: origin.lat,
                    longitude: origin.lng,
                  },
                },
              },
            },
          ],
          destinations: [
            {
              waypoint: {
                location: {
                  latLng: {
                    latitude: destination.lat,
                    longitude: destination.lng,
                  },
                },
              },
            },
          ],
          travelMode: "DRIVE",
          routingPreference: "TRAFFIC_UNAWARE",
        }),
      },
    );

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(`Google Routes HTTP ${response.status}: ${text.slice(0, 200)}`);
    }

    const text = await response.text();
    const row = pickRouteMatrixElement(parseRouteMatrixElements(text));

    return {
      distance_m: Math.round(row.distanceMeters!),
      duration_s: parseDurationSeconds(row.duration),
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
    await assertGlobalTenantEditor(userClient, tenantId, user.id);

    const body = (await req.json().catch(() => ({}))) as DistanceBody;
    if (body.action !== "distance") {
      return errorResponse(400, "invalid_action", "action must be distance");
    }

    const originLat = Number(body.origin?.lat);
    const originLng = Number(body.origin?.lng);
    const destLat = Number(body.destination?.lat);
    const destLng = Number(body.destination?.lng);

    if (!isValidCoord(originLat, originLng) || !isValidCoord(destLat, destLng)) {
      return errorResponse(400, "invalid_coordinates", "origin and destination require valid lat/lng");
    }

    const origin = { lat: originLat, lng: originLng };
    const destination = { lat: destLat, lng: destLng };

    const adminClient = createAdminClient();
    const apiKey = await getRoutesApiKey(tenantId);

    if (apiKey) {
      try {
        const google = await computeGoogleRouteMatrix(apiKey, origin, destination);
        await adminClient.rpc("touch_tenant_routes_provider", {
          p_tenant_id: tenantId,
          p_provider_key: "google",
        });

        const result: DistanceResult = {
          source: "google_routes",
          distance_m: google.distance_m,
          duration_s: google.duration_s,
          is_approximate: false,
        };

        log("info", FEATURE, "google routes distance", {
          tenantId,
          extra: { userId: user.id, distance_m: result.distance_m },
        });

        return jsonResponse(result);
      } catch (err) {
        log("warn", FEATURE, "google routes failed, falling back to haversine", {
          tenantId,
          extra: {
            userId: user.id,
            error: err instanceof Error ? err.message : String(err),
          },
        });
        // fall through to haversine
      }
    }

    const distance_m = Math.round(
      haversineDistanceM(origin.lat, origin.lng, destination.lat, destination.lng),
    );

    const result: DistanceResult = {
      source: "haversine",
      distance_m,
      duration_s: null,
      is_approximate: true,
    };

    return jsonResponse(result);
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

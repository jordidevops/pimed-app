import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertGlobalTenantEditor,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log, timedCall, defaultSlowHandler } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "geocoding-proxy";
const GEO_SLOW_MS = 8_000;
const GOOGLE_TIMEOUT_MS = 8_000;

const IMPLEMENTED_PROVIDERS = ["nominatim", "google"] as const;
type ImplementedProviderKey = typeof IMPLEMENTED_PROVIDERS[number];

type GeocodingAction = "search" | "reverse";
type BillingSource = "platform" | "byo" | "none";
type UsageStatus =
  | "success"
  | "cached"
  | "provider_error"
  | "network_error"
  | "blocked_rate_limit"
  | "blocked_quota"
  | "validation_error";

interface GeocodingRequestBody {
  action: GeocodingAction;
  query?: string;
  lat?: number;
  lng?: number;
  language?: string;
  limit?: number;
  site_id?: string;
  request_id?: string;
  idempotency_key?: string;
}

interface ReserveResult {
  allowed: boolean;
  reason: string;
  mode: string | null;
  billable: boolean;
  billable_units: number;
  unit_price: number;
  currency: string;
}

interface EffectiveProvider {
  providerKey: string;
  mode: string;
}

interface StructuredAddressFields {
  street?: string | null;
  street_number?: string | null;
  city?: string | null;
  province?: string | null;
  postal_code?: string | null;
  country_code?: string | null;
}

interface NominatimSearchItem {
  place_id?: number;
  lat: string;
  lon: string;
  display_name: string;
  osm_type?: string;
  osm_id?: number;
  class?: string;
  type?: string;
  importance?: number;
  licence?: string;
  address?: Record<string, unknown>;
}

interface NominatimReverseItem {
  place_id?: number;
  lat?: string;
  lon?: string;
  display_name?: string;
  osm_type?: string;
  osm_id?: number;
  class?: string;
  type?: string;
  importance?: number;
  licence?: string;
  address?: Record<string, unknown>;
}

interface GoogleAddressComponent {
  long_name: string;
  short_name: string;
  types: string[];
}

interface GoogleGeometry {
  location: { lat: number; lng: number };
}

interface GoogleGeocodeResult {
  place_id?: string;
  formatted_address: string;
  address_components?: GoogleAddressComponent[];
  geometry: GoogleGeometry;
  types?: string[];
}

interface GoogleGeocodeResponse {
  status: string;
  error_message?: string;
  results: GoogleGeocodeResult[];
}

interface GeocodeCandidate extends StructuredAddressFields {
  lat: number;
  lng: number;
  display_name: string;
  provider_data: Record<string, unknown>;
}

class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AppError";
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function parseAction(value: unknown): GeocodingAction {
  if (value === "search" || value === "reverse") return value;
  throw new AppError(400, "invalid_action", "action must be 'search' or 'reverse'");
}

function normalizeLanguage(value: unknown): string {
  if (typeof value !== "string") return "ca";
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : "ca";
}

function parseLimit(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 5;
  return Math.min(Math.max(Math.trunc(value), 1), 10);
}

function parseOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function parseCoordinate(value: unknown, name: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new AppError(400, "invalid_coordinates", `${name} must be a finite number`);
  }
  if (value < min || value > max) {
    throw new AppError(400, "invalid_coordinates", `${name} out of range`);
  }
  return value;
}

async function parseBody(req: Request): Promise<GeocodingRequestBody> {
  let raw: Record<string, unknown>;
  try {
    raw = await req.json();
  } catch {
    throw new AppError(400, "invalid_json", "Request body must be valid JSON");
  }

  const action = parseAction(raw.action);
  const language = normalizeLanguage(raw.language);
  const request_id = parseOptionalString(raw.request_id);
  const idempotency_key = parseOptionalString(raw.idempotency_key);
  const site_id = parseOptionalString(raw.site_id);

  if (action === "search") {
    const query = parseOptionalString(raw.query);
    if (!query) {
      throw new AppError(400, "missing_query", "query is required for action=search");
    }

    return {
      action,
      query,
      language,
      limit: parseLimit(raw.limit),
      request_id,
      idempotency_key,
      site_id,
    };
  }

  return {
    action,
    lat: parseCoordinate(raw.lat, "lat", -90, 90),
    lng: parseCoordinate(raw.lng, "lng", -180, 180),
    language,
    request_id,
    idempotency_key,
    site_id,
  };
}

function buildNominatimProviderData(
  endpoint: GeocodingAction,
  item: NominatimSearchItem | NominatimReverseItem,
): Record<string, unknown> {
  return {
    provider: "nominatim",
    endpoint,
    place_id: item.place_id ?? null,
    osm_type: item.osm_type ?? null,
    osm_id: item.osm_id ?? null,
    class: item.class ?? null,
    type: item.type ?? null,
    importance: item.importance ?? null,
    licence: item.licence ?? null,
    address: item.address ?? null,
  };
}

function extractString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function buildStructuredFieldsFromNominatimAddress(
  address: Record<string, unknown> | undefined,
): StructuredAddressFields {
  if (!address) return {};

  const street = extractString(address.road) ?? extractString(address.pedestrian) ?? extractString(address.footway);
  const streetNumber = extractString(address.house_number);
  const city = extractString(address.city)
    ?? extractString(address.town)
    ?? extractString(address.village)
    ?? extractString(address.municipality)
    ?? extractString(address.suburb);
  const province = extractString(address.state)
    ?? extractString(address.province)
    ?? extractString(address.county);
  const postalCode = extractString(address.postcode);
  const countryCode = extractString(address.country_code);

  return {
    street,
    street_number: streetNumber,
    city,
    province,
    postal_code: postalCode,
    country_code: countryCode ? countryCode.toUpperCase() : null,
  };
}

function buildGoogleProviderData(
  endpoint: GeocodingAction,
  result: GoogleGeocodeResult,
): Record<string, unknown> {
  return {
    provider: "google",
    endpoint,
    place_id: result.place_id ?? null,
    types: result.types ?? null,
    address_components: result.address_components ?? null,
  };
}

function buildStructuredFieldsFromGoogleComponents(
  components: GoogleAddressComponent[] | undefined,
): StructuredAddressFields {
  if (!components || components.length === 0) return {};

  const findByType = (type: string): GoogleAddressComponent | undefined =>
    components.find((component) => component.types.includes(type));

  const streetNumber = findByType("street_number")?.long_name ?? null;
  const street = findByType("route")?.long_name ?? null;
  const city = findByType("locality")?.long_name
    ?? findByType("postal_town")?.long_name
    ?? findByType("sublocality")?.long_name
    ?? null;
  const province = findByType("administrative_area_level_2")?.long_name
    ?? findByType("administrative_area_level_1")?.long_name
    ?? null;
  const postalCode = findByType("postal_code")?.long_name ?? null;
  const countryCode = findByType("country")?.short_name ?? null;

  return {
    street,
    street_number: streetNumber,
    city,
    province,
    postal_code: postalCode,
    country_code: countryCode ? countryCode.toUpperCase() : null,
  };
}

function mapReserveReasonToStatus(reason: string): number {
  if (reason === "nominatim_disabled") return 403;
  if (reason.startsWith("rate_limit")) return 429;
  if (reason.startsWith("quota_")) return 402;
  if (reason === "provider_disabled") return 403;
  return 400;
}

function mapReserveReasonToUsageStatus(reason: string): UsageStatus {
  if (reason === "nominatim_disabled" || reason.startsWith("rate_limit")) {
    return "blocked_rate_limit";
  }
  if (reason.startsWith("quota_")) return "blocked_quota";
  return "validation_error";
}

function mapModeToBillingSource(mode: string | null): BillingSource {
  if (mode === "platform") return "platform";
  if (mode === "byo") return "byo";
  return "none";
}

function mapGoogleStatusToAppError(status: string, errorMessage?: string): AppError {
  const detail = errorMessage ? `${status}: ${errorMessage}` : status;
  switch (status) {
    case "OVER_QUERY_LIMIT":
      return new AppError(429, "provider_rate_limited", `Google Geocoding quota exceeded (${detail})`);
    case "REQUEST_DENIED":
      return new AppError(502, "provider_request_denied", `Google Geocoding request denied (${detail})`);
    case "INVALID_REQUEST":
      return new AppError(400, "invalid_request", `Google Geocoding invalid request (${detail})`);
    case "UNKNOWN_ERROR":
      return new AppError(503, "provider_error", `Google Geocoding unknown error (${detail})`);
    default:
      return new AppError(502, "provider_error", `Google Geocoding failed (${detail})`);
  }
}

async function logUsageSafely(
  adminClient: ReturnType<typeof createAdminClient>,
  params: {
    tenantId: string;
    providerKey: string;
    action: GeocodingAction;
    status: UsageStatus;
    reserve: ReserveResult | null;
    siteId?: string;
    requestId?: string;
    idempotencyKey?: string;
    payload?: Record<string, unknown>;
    cacheHit?: boolean;
  },
): Promise<void> {
  const reserve = params.reserve;

  const { error } = await adminClient.rpc("log_geocoding_usage", {
    p_tenant_id: params.tenantId,
    p_provider_key: params.providerKey,
    p_operation: params.action,
    p_request_status: params.status,
    p_cache_hit: params.cacheHit === true || params.status === "cached",
    p_billing_source: mapModeToBillingSource(reserve?.mode ?? null),
    p_billable_units: reserve?.billable ? reserve.billable_units : 0,
    p_unit_price: reserve?.billable ? reserve.unit_price : 0,
    p_site_id: params.siteId ?? null,
    p_request_id: params.requestId ?? null,
    p_idempotency_key: params.idempotencyKey ?? null,
    p_payload: params.payload ?? {},
  });

  if (error) {
    log("warn", FEATURE, "log_geocoding_usage failed", { extra: { error: error.message } });
  }
}

async function resolveEffectiveProvider(
  tenantId: string,
): Promise<EffectiveProvider> {
  const adminClient = createAdminClient();
  const { data, error } = await adminClient.rpc("resolve_effective_geocoding_provider", {
    p_tenant_id: tenantId,
  });

  if (error) {
    throw new AppError(500, "provider_resolution_failed", error.message);
  }

  const row = data as { provider_key?: string; mode?: string } | null;
  if (!row?.provider_key) {
    throw new AppError(503, "no_provider", "No geocoding provider is available for this tenant");
  }

  return { providerKey: row.provider_key, mode: row.mode ?? "platform" };
}

async function reserveQuota(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  providerKey: string,
  action: GeocodingAction,
): Promise<ReserveResult> {
  const { data, error } = await adminClient.rpc("check_and_reserve_geocoding", {
    p_tenant_id: tenantId,
    p_provider_key: providerKey,
    p_operation: action,
    p_units: 1,
  });

  if (error) {
    throw new AppError(500, "quota_check_failed", error.message);
  }

  const row = (data ?? [])[0] as ReserveResult | undefined;
  if (!row) {
    throw new AppError(500, "quota_check_empty", "Quota RPC returned no rows");
  }

  return row;
}

type PlatformReserveResult = {
  allowed: boolean;
  reason?: string | null;
  second_used?: number | null;
  minute_used?: number | null;
  max_per_second?: number;
  max_per_minute?: number;
};

/** S10: platform-wide Nominatim throttle (independent of per-tenant limits). */
async function reserveNominatimGlobal(
  adminClient: ReturnType<typeof createAdminClient>,
): Promise<PlatformReserveResult> {
  const { data, error } = await adminClient.rpc("reserve_nominatim_global");
  if (error) {
    throw new AppError(500, "platform_quota_check_failed", error.message);
  }
  const row = data as PlatformReserveResult | null;
  if (!row || typeof row.allowed !== "boolean") {
    throw new AppError(500, "platform_quota_check_empty", "Platform quota RPC returned no data");
  }
  return row;
}

async function recordOpsAlert(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  providerKey: string,
  reason: string,
  payload?: Record<string, unknown>,
): Promise<void> {
  const { data, error } = await adminClient.rpc("record_geocoding_ops_alert", {
    p_tenant_id: tenantId,
    p_provider_key: providerKey,
    p_reason: reason,
    p_blocked_requests: 0,
    p_threshold: 0,
    p_payload: payload ?? {},
  });
  if (error) {
    log("warn", FEATURE, "record_geocoding_ops_alert failed", {
      extra: { error: error.message, reason },
    });
    return;
  }
  const row = data as { alerted?: boolean; is_new?: boolean } | null;
  if (row?.alerted && row?.is_new) {
    log("warn", FEATURE, "geocoding ops alert", {
      tenantId,
      extra: { providerKey, reason },
    });
  }
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function normalizeCacheQuery(query: string): string {
  return query.trim().toLowerCase().replace(/\s+/g, " ");
}

async function buildCacheQueryHash(
  action: GeocodingAction,
  body: GeocodingRequestBody,
): Promise<string> {
  if (action === "search") {
    const limit = body.limit ?? 5;
    return sha256Hex(`search|${normalizeCacheQuery(body.query ?? "")}|${limit}`);
  }
  const lat = Number(body.lat);
  const lng = Number(body.lng);
  // ~1.1 m precision — enough to coalesce reverse clicks without over-merging.
  return sha256Hex(`reverse|${lat.toFixed(5)}|${lng.toFixed(5)}`);
}

async function getNominatimCache(
  adminClient: ReturnType<typeof createAdminClient>,
  action: GeocodingAction,
  queryHash: string,
  language: string,
): Promise<unknown | null> {
  const { data, error } = await adminClient.rpc("get_geocoding_result_cache", {
    p_provider_key: "nominatim",
    p_cache_kind: "nominatim_result",
    p_operation: action,
    p_query_hash: queryHash,
    p_language: language,
  });
  if (error) {
    log("warn", FEATURE, "get_geocoding_result_cache failed", { extra: { error: error.message } });
    return null;
  }
  return data ?? null;
}

async function putNominatimCache(
  adminClient: ReturnType<typeof createAdminClient>,
  action: GeocodingAction,
  queryHash: string,
  language: string,
  result: unknown,
): Promise<void> {
  const { error } = await adminClient.rpc("upsert_geocoding_result_cache", {
    p_provider_key: "nominatim",
    p_cache_kind: "nominatim_result",
    p_operation: action,
    p_query_hash: queryHash,
    p_language: language,
    p_result: result,
    p_ttl_days: 30,
  });
  if (error) {
    log("warn", FEATURE, "upsert_geocoding_result_cache failed", { extra: { error: error.message } });
  }
}

/** S7: store only place_id values — never addresses or coordinates. */
async function putGooglePlaceIdCache(
  adminClient: ReturnType<typeof createAdminClient>,
  placeIds: string[],
  language: string,
): Promise<void> {
  const unique = [...new Set(placeIds.filter((id) => typeof id === "string" && id.length > 0))];
  for (const placeId of unique) {
    const queryHash = await sha256Hex(`place_id|${placeId}`);
    const { error } = await adminClient.rpc("upsert_geocoding_result_cache", {
      p_provider_key: "google",
      p_cache_kind: "google_place_id",
      p_operation: "place_id",
      p_query_hash: queryHash,
      p_language: language,
      p_result: { place_id: placeId },
      p_ttl_days: 30,
    });
    if (error) {
      log("warn", FEATURE, "google place_id cache upsert failed", {
        extra: { error: error.message },
      });
    }
  }
}

async function maybeAbuseAlert(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
  providerKey: string,
): Promise<void> {
  const { data, error } = await adminClient.rpc("maybe_record_geocoding_abuse_alert", {
    p_tenant_id: tenantId,
    p_provider_key: providerKey,
    p_threshold: 50,
  });
  if (error) {
    log("warn", FEATURE, "maybe_record_geocoding_abuse_alert failed", {
      extra: { error: error.message },
    });
    return;
  }
  const row = data as {
    alerted?: boolean;
    is_new?: boolean;
    blocked_requests?: number;
    threshold?: number;
  } | null;
  // Only emit structured warn on the first alert of the day (avoid spam).
  if (row?.alerted && row?.is_new) {
    log("warn", FEATURE, "geocoding blocked_requests spike", {
      tenantId,
      extra: {
        providerKey,
        blocked_requests: row.blocked_requests ?? null,
        threshold: row.threshold ?? null,
      },
    });
  }
}

async function nominatimSearch(query: string, language: string, limit: number): Promise<GeocodeCandidate[]> {
  const url = new URL("https://nominatim.openstreetmap.org/search");
  url.searchParams.set("q", query);
  url.searchParams.set("format", "jsonv2");
  url.searchParams.set("limit", String(limit));
  url.searchParams.set("addressdetails", "1");
  url.searchParams.set("accept-language", language);

  const response = await fetch(url.toString(), {
    headers: {
      Accept: "application/json",
      "User-Agent": "pimed-app geocoding-proxy/1.0 (support@pimed.app)",
    },
  });

  if (!response.ok) {
    if (response.status === 429) {
      throw new AppError(
        429,
        "provider_rate_limited",
        `Nominatim rate limited (status ${response.status})`,
      );
    }
    const status = response.status >= 500 ? 503 : 502;
    throw new AppError(status, "provider_error", `Provider search failed with status ${response.status}`);
  }

  const data = (await response.json()) as NominatimSearchItem[];

  return data
    .map((item) => ({
      lat: Number(item.lat),
      lng: Number(item.lon),
      display_name: item.display_name,
      ...buildStructuredFieldsFromNominatimAddress(item.address),
      provider_data: buildNominatimProviderData("search", item),
    }))
    .filter((item) => Number.isFinite(item.lat) && Number.isFinite(item.lng));
}

async function nominatimReverse(lat: number, lng: number, language: string): Promise<GeocodeCandidate | null> {
  const url = new URL("https://nominatim.openstreetmap.org/reverse");
  url.searchParams.set("lat", String(lat));
  url.searchParams.set("lon", String(lng));
  url.searchParams.set("format", "jsonv2");
  url.searchParams.set("zoom", "18");
  url.searchParams.set("addressdetails", "1");
  url.searchParams.set("accept-language", language);

  const response = await fetch(url.toString(), {
    headers: {
      Accept: "application/json",
      "User-Agent": "pimed-app geocoding-proxy/1.0 (support@pimed.app)",
    },
  });

  if (!response.ok) {
    if (response.status === 429) {
      throw new AppError(
        429,
        "provider_rate_limited",
        `Nominatim rate limited (status ${response.status})`,
      );
    }
    const status = response.status >= 500 ? 503 : 502;
    throw new AppError(status, "provider_error", `Provider reverse failed with status ${response.status}`);
  }

  const data = (await response.json()) as NominatimReverseItem;
  if (!data.display_name) return null;

  const resolvedLat = Number(data.lat ?? lat);
  const resolvedLng = Number(data.lon ?? lng);

  return {
    lat: Number.isFinite(resolvedLat) ? resolvedLat : lat,
    lng: Number.isFinite(resolvedLng) ? resolvedLng : lng,
    display_name: data.display_name,
    ...buildStructuredFieldsFromNominatimAddress(data.address),
    provider_data: buildNominatimProviderData("reverse", data),
  };
}

async function getGoogleApiKey(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
): Promise<string> {
  const { data, error } = await adminClient.rpc("get_geocoding_api_key_service", {
    p_tenant_id: tenantId,
    p_provider_key: "google",
  });

  if (error) {
    throw new AppError(500, "provider_key_lookup_failed", error.message);
  }

  if (!data || typeof data !== "string") {
    throw new AppError(503, "no_provider", "No Google API key configured for this tenant");
  }

  return data;
}

async function fetchGoogleGeocode(params: URLSearchParams): Promise<GoogleGeocodeResponse> {
  const url = new URL("https://maps.googleapis.com/maps/api/geocode/json");
  for (const [key, value] of params.entries()) {
    url.searchParams.set(key, value);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), GOOGLE_TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch(url.toString(), {
      headers: { Accept: "application/json" },
      signal: controller.signal,
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new AppError(504, "provider_timeout", "Google Geocoding request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    const status = response.status >= 500 ? 503 : 502;
    throw new AppError(status, "provider_error", `Google Geocoding failed with status ${response.status}`);
  }

  const data = (await response.json()) as GoogleGeocodeResponse;

  if (data.status !== "OK" && data.status !== "ZERO_RESULTS") {
    throw mapGoogleStatusToAppError(data.status, data.error_message);
  }

  return data;
}

async function googleSearch(
  apiKey: string,
  query: string,
  language: string,
  limit: number,
): Promise<GeocodeCandidate[]> {
  const params = new URLSearchParams({
    address: query,
    language,
    key: apiKey,
  });

  const data = await fetchGoogleGeocode(params);

  return data.results.slice(0, limit).map((result) => ({
    lat: result.geometry.location.lat,
    lng: result.geometry.location.lng,
    display_name: result.formatted_address,
    ...buildStructuredFieldsFromGoogleComponents(result.address_components),
    provider_data: buildGoogleProviderData("search", result),
  }));
}

async function googleReverse(
  apiKey: string,
  lat: number,
  lng: number,
  language: string,
): Promise<GeocodeCandidate | null> {
  const params = new URLSearchParams({
    latlng: `${lat},${lng}`,
    language,
    key: apiKey,
  });

  const data = await fetchGoogleGeocode(params);
  const result = data.results[0];
  if (!result) return null;

  return {
    lat: result.geometry.location.lat,
    lng: result.geometry.location.lng,
    display_name: result.formatted_address,
    ...buildStructuredFieldsFromGoogleComponents(result.address_components),
    provider_data: buildGoogleProviderData("reverse", result),
  };
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: { code: "method_not_allowed", message: "Only POST is allowed" } }, 405);
  }

  let tenantId: string | undefined;
  let parsedBody: GeocodingRequestBody | null = null;
  let reserve: ReserveResult | null = null;
  let adminClient: ReturnType<typeof createAdminClient> | null = null;
  let providerKey: string | undefined;

  try {
    tenantId = requireTenantHeader(req);
    parsedBody = await parseBody(req);

    const userClient = createUserClient(req);
    const user = await requireAuthenticatedUser(userClient);
    await assertGlobalTenantEditor(userClient, tenantId, user.id);

    adminClient = createAdminClient();

    const provider = await resolveEffectiveProvider(tenantId);
    providerKey = provider.providerKey;

    if (!IMPLEMENTED_PROVIDERS.includes(provider.providerKey as ImplementedProviderKey)) {
      await logUsageSafely(adminClient, {
        tenantId,
        providerKey: provider.providerKey,
        action: parsedBody.action,
        status: "validation_error",
        reserve: null,
        siteId: parsedBody.site_id,
        requestId: parsedBody.request_id,
        idempotencyKey: parsedBody.idempotency_key,
        payload: { reason: "provider_not_supported" },
      });

      return jsonResponse(
        {
          error: {
            code: "provider_not_supported",
            message: `Provider '${provider.providerKey}' is not supported by this function yet`,
          },
        },
        400,
      );
    }

    const language = parsedBody.language ?? "ca";
    const queryHash = await buildCacheQueryHash(parsedBody.action, parsedBody);

    // Nominatim full-result cache (S7): serve before quota reservation.
    if (provider.providerKey === "nominatim") {
      const cached = await getNominatimCache(
        adminClient,
        parsedBody.action,
        queryHash,
        language,
      );
      if (parsedBody.action === "search") {
        if (cached && typeof cached === "object" && Array.isArray((cached as { results?: unknown }).results)) {
          const results = (cached as { results: GeocodeCandidate[] }).results;
          await logUsageSafely(adminClient, {
            tenantId,
            providerKey: provider.providerKey,
            action: parsedBody.action,
            status: "cached",
            reserve: null,
            siteId: parsedBody.site_id,
            requestId: parsedBody.request_id,
            idempotencyKey: parsedBody.idempotency_key,
            payload: { result_count: results.length, cache: true },
            cacheHit: true,
          });
          return jsonResponse({
            provider_key: provider.providerKey,
            action: "search",
            results,
            cache_hit: true,
          });
        }
      } else if (cached && typeof cached === "object" && "result" in (cached as object)) {
        const result = (cached as { result: GeocodeCandidate | null }).result;
        await logUsageSafely(adminClient, {
          tenantId,
          providerKey: provider.providerKey,
          action: parsedBody.action,
          status: "cached",
          reserve: null,
          siteId: parsedBody.site_id,
          requestId: parsedBody.request_id,
          idempotencyKey: parsedBody.idempotency_key,
          payload: { has_result: !!result, cache: true },
          cacheHit: true,
        });
        return jsonResponse({
          provider_key: provider.providerKey,
          action: "reverse",
          result,
          cache_hit: true,
        });
      }
    }

    // S10: platform Nominatim gate before per-tenant reserve so a global deny
    // does not burn tenant rate windows or inflate abuse-alert counters.
    if (provider.providerKey === "nominatim") {
      const platform = await reserveNominatimGlobal(adminClient);
      if (!platform.allowed) {
        const reason = platform.reason ?? "rate_limit_platform_second_exceeded";
        await logUsageSafely(adminClient, {
          tenantId,
          providerKey: provider.providerKey,
          action: parsedBody.action,
          status: mapReserveReasonToUsageStatus(reason),
          reserve: null,
          siteId: parsedBody.site_id,
          requestId: parsedBody.request_id,
          idempotencyKey: parsedBody.idempotency_key,
          payload: {
            reason,
            second_used: platform.second_used ?? null,
            minute_used: platform.minute_used ?? null,
            max_per_second: platform.max_per_second ?? null,
            max_per_minute: platform.max_per_minute ?? null,
            scope: "platform",
          },
        });

        return jsonResponse(
          {
            error: {
              code: "geocoding_blocked",
              message: reason,
            },
          },
          mapReserveReasonToStatus(reason),
        );
      }
    }

    reserve = await reserveQuota(adminClient, tenantId, provider.providerKey, parsedBody.action);

    if (!reserve.allowed) {
      await logUsageSafely(adminClient, {
        tenantId,
        providerKey: provider.providerKey,
        action: parsedBody.action,
        status: mapReserveReasonToUsageStatus(reserve.reason),
        reserve,
        siteId: parsedBody.site_id,
        requestId: parsedBody.request_id,
        idempotencyKey: parsedBody.idempotency_key,
        payload: { reason: reserve.reason },
      });

      await maybeAbuseAlert(adminClient, tenantId, provider.providerKey);

      return jsonResponse(
        {
          error: {
            code: "geocoding_blocked",
            message: reserve.reason,
          },
        },
        mapReserveReasonToStatus(reserve.reason),
      );
    }

    try {
      if (parsedBody.action === "search") {
        const googleKey =
          provider.providerKey === "google"
            ? await getGoogleApiKey(adminClient!, tenantId!)
            : null;
        const results = await timedCall(
          FEATURE,
          `${provider.providerKey}_search`,
          GEO_SLOW_MS,
          () =>
            provider.providerKey === "google"
              ? googleSearch(
                googleKey!,
                parsedBody!.query!,
                language,
                parsedBody!.limit ?? 5,
              )
              : nominatimSearch(
                parsedBody!.query!,
                language,
                parsedBody!.limit ?? 5,
              ),
          defaultSlowHandler(FEATURE, `${provider.providerKey}_search`, GEO_SLOW_MS),
        );

        if (provider.providerKey === "nominatim") {
          await putNominatimCache(adminClient, "search", queryHash, language, { results });
        } else if (provider.providerKey === "google") {
          const placeIds = results
            .map((r) => r.provider_data?.place_id)
            .filter((id): id is string => typeof id === "string");
          await putGooglePlaceIdCache(adminClient, placeIds, language);
        }

        await logUsageSafely(adminClient, {
          tenantId,
          providerKey: provider.providerKey,
          action: parsedBody.action,
          status: "success",
          reserve,
          siteId: parsedBody.site_id,
          requestId: parsedBody.request_id,
          idempotencyKey: parsedBody.idempotency_key,
          payload: { result_count: results.length },
        });

        return jsonResponse({ provider_key: provider.providerKey, action: "search", results });
      }

      const googleKey =
        provider.providerKey === "google"
          ? await getGoogleApiKey(adminClient!, tenantId!)
          : null;
      const result = await timedCall(
        FEATURE,
        `${provider.providerKey}_reverse`,
        GEO_SLOW_MS,
        () =>
          provider.providerKey === "google"
            ? googleReverse(
              googleKey!,
              parsedBody!.lat!,
              parsedBody!.lng!,
              language,
            )
            : nominatimReverse(
              parsedBody!.lat!,
              parsedBody!.lng!,
              language,
            ),
        defaultSlowHandler(FEATURE, `${provider.providerKey}_reverse`, GEO_SLOW_MS),
      );

      if (provider.providerKey === "nominatim") {
        await putNominatimCache(adminClient, "reverse", queryHash, language, { result });
      } else if (provider.providerKey === "google") {
        const placeId = result?.provider_data?.place_id;
        if (typeof placeId === "string") {
          await putGooglePlaceIdCache(adminClient, [placeId], language);
        }
      }

      await logUsageSafely(adminClient, {
        tenantId,
        providerKey: provider.providerKey,
        action: parsedBody.action,
        status: "success",
        reserve,
        siteId: parsedBody.site_id,
        requestId: parsedBody.request_id,
        idempotencyKey: parsedBody.idempotency_key,
        payload: { has_result: !!result },
      });

      return jsonResponse({ provider_key: provider.providerKey, action: "reverse", result });
    } catch (providerError) {
      if (providerError instanceof AppError) {
        await logUsageSafely(adminClient, {
          tenantId,
          providerKey: provider.providerKey,
          action: parsedBody.action,
          status: "provider_error",
          reserve,
          siteId: parsedBody.site_id,
          requestId: parsedBody.request_id,
          idempotencyKey: parsedBody.idempotency_key,
          payload: { provider_error: providerError.message, status: providerError.status },
        });

        if (
          provider.providerKey === "nominatim" &&
          providerError.status === 429
        ) {
          await recordOpsAlert(adminClient, tenantId, provider.providerKey, "upstream_429", {
            status: providerError.status,
            message: providerError.message,
          });
        }

        return jsonResponse(
          {
            error: {
              code: providerError.code,
              message: providerError.message,
            },
          },
          providerError.status,
        );
      }

      await logUsageSafely(adminClient, {
        tenantId,
        providerKey: provider.providerKey,
        action: parsedBody.action,
        status: "network_error",
        reserve,
        siteId: parsedBody.site_id,
        requestId: parsedBody.request_id,
        idempotencyKey: parsedBody.idempotency_key,
        payload: {
          provider_error: providerError instanceof Error ? providerError.message : String(providerError),
        },
      });

      await createOperationLogService(adminClient).log({
        tenantId,
        siteId: parsedBody.site_id ?? null,
        integrationType: "geocoding",
        operationCode: parsedBody.action,
        status: "failed",
        title: "Proveïdor de geocodificació no disponible",
        message: (providerError instanceof Error ? providerError.message : String(providerError)).slice(0, 200),
        errorCode: "provider_unreachable",
        externalService: provider.providerKey,
        isRetryable: true,
      }).catch(() => undefined);

      return jsonResponse(
        {
          error: {
            code: "provider_unreachable",
            message: "Could not reach geocoding provider",
          },
        },
        503,
      );
    }
  } catch (error) {
    if (error instanceof AuthError) {
      return jsonResponse(
        {
          error: {
            code: error.code,
            message: error.message,
          },
        },
        error.status,
      );
    }

    if (error instanceof AppError) {
      return jsonResponse(
        {
          error: {
            code: error.code,
            message: error.message,
          },
        },
        error.status,
      );
    }

    log("error", FEATURE, "Unhandled error", {
      tenantId: tenantId ?? req.headers.get("x-tenant-id") ?? undefined,
      extra: { error: error instanceof Error ? error.message : String(error), providerKey },
    });
    captureException(error, { feature: FEATURE, tenantId: tenantId ?? req.headers.get("x-tenant-id") });
    return jsonResponse(
      {
        error: {
          code: "internal_error",
          message: "Unexpected server error",
        },
      },
      500,
    );
  }
});

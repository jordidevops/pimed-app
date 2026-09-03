/**
 * station-api — Edge Function per estacions de fitxatge (ST-2/ST-3)
 *
 * Auth: header Authorization: Bearer {device_public_id}:{device_secret}
 * Routes:
 *   POST /register
 *   GET  /bootstrap
 *   GET  /employees
 *   GET  /pause-configs
 *   POST /employee-location-hint
 *   POST /verify-pin
 *   POST /verify-employee-pin
 *   POST /employee-history
 *   POST /resolve-identity
 *   POST /resolve-employee-document
 *   POST /heartbeat
 *   POST /punch
 *   GET  /health
 */

import { corsHeaders } from "../_shared/cors.ts";
import {
  getStationEmployeeHistory,
  getStationEmployeeLocationHint,
  listStationEmployees,
  listStationPauseConfigs,
  recordStationHeartbeat,
  recordStationPunch,
  registerStationDevice,
  resolveStationEmployeeDocument,
  isStationOfflineDeferredEnabled,
  verifyStationCredentials,
  verifyStationEmployeePin,
  verifyStationLocalPin,
} from "../_shared/attendance-station/repository.ts";
import { resolveAttendanceIdentityToken } from "../_shared/attendance-station/identity-service.ts";
import {
  generateClientOpId,
  generateDevicePublicId,
  generateDeviceSecret,
  isValidStationPin,
} from "../_shared/attendance-station/crypto.ts";
import {
  assertStationDocumentResolveRateLimit,
  assertStationRegisterRateLimit,
  extractStationClientKey,
  recordStationRateLimitBlock,
  StationDocumentResolveRateLimitError,
  StationRegisterRateLimitError,
} from "../_shared/attendance-station/rate-limit.ts";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(
  code: string,
  message: string,
  status = 400,
  extra?: Record<string, unknown>,
): Response {
  return jsonResponse({ error: { code, message, ...extra } }, status);
}

function mapStationRpcError(message: string): { code: string; status: number } {
  const normalized = message.toLowerCase();

  if (
    normalized.includes("station_not_found")
    || normalized.includes("device_not_found")
  ) {
    return { code: "station_not_found", status: 404 };
  }

  if (
    normalized.includes("missing_station_auth")
    || normalized.includes("station_invalid_secret")
    || normalized.includes("station_auth_failed")
    || normalized.includes("insufficient_privilege")
    || normalized.includes("not authenticated")
  ) {
    return { code: "station_auth_failed", status: 401 };
  }

  if (
    normalized.includes("employee_not_allowed_at_station")
    || normalized.includes("employee_not_allowed_at_location")
  ) {
    return {
      code: message.split(":")[0]?.trim() || "employee_not_allowed",
      status: 403,
    };
  }

  if (normalized.includes("wrong_scheduled_location")) {
    return { code: "wrong_scheduled_location", status: 409 };
  }

  if (normalized.includes("station_punch_not_monotonic")) {
    return { code: "station_punch_not_monotonic", status: 409 };
  }

  if (normalized.includes("station_punch_too_old")) {
    return { code: "station_punch_too_old", status: 409 };
  }

  if (normalized.includes("station_offline_disabled")) {
    return { code: "station_offline_disabled", status: 403 };
  }

  if (normalized.includes("invalid_occurred_at")) {
    return { code: "invalid_occurred_at", status: 400 };
  }

  if (
    normalized.includes("station_register_rate_limited")
  ) {
    return { code: "station_register_rate_limited", status: 429 };
  }

  if (
    normalized.includes("station_pin_locked")
    || normalized.includes("station_identity_issue_rate_limited")
    || normalized.includes("station_identity_resolve_rate_limited")
    || normalized.includes("rate_limited")
    || normalized.includes("rate limit")
  ) {
    if (normalized.includes("station_identity_issue_rate_limited")) {
      return { code: "station_identity_issue_rate_limited", status: 429 };
    }
    if (normalized.includes("station_identity_resolve_rate_limited")) {
      return { code: "station_identity_resolve_rate_limited", status: 429 };
    }
    if (normalized.includes("station_document_resolve_rate_limited")) {
      return { code: "station_document_resolve_rate_limited", status: 429 };
    }
    if (normalized.includes("station_employee_pin_locked")) {
      return { code: "station_employee_pin_locked", status: 429 };
    }
    return { code: "rate_limited", status: 429 };
  }

  const client409 =
    normalized.includes("invalid_sequence")
    || normalized.includes("station_wrong_punch_type")
    || normalized.includes("station_punch_blocked")
    || normalized.includes("station_punch_type_not_allowed")
    || normalized.includes("identity_token")
    || normalized.includes("station_qr_not_allowed")
    || normalized.includes("station_manual_not_allowed")
    || normalized.includes("station_history_disabled")
    || normalized.includes("station_history_range_too_large")
    || normalized.includes("invalid_date_range")
    || normalized.includes("unsafe_station_config")
    || normalized.includes("employee_not_allowed")
    || normalized.includes("station_geo_")
    || normalized.includes("geo_antifraud_")
    || normalized.includes("station_not_ready")
    || normalized.includes("station_not_active")
    || normalized.includes("station_missing_location")
    || normalized.includes("invalid_station_punch_source")
    || normalized.includes("missing_pause_type")
    || normalized.includes("invalid_pause_type")
    || normalized.includes("station_punch_requires_device")
    || normalized.includes("employee_not_active")
    || normalized.includes("employee_no_site")
    || normalized.includes("check_violation");

  if (client409) {
    return { code: message.split(":")[0]?.trim() || "station_conflict", status: 409 };
  }

  return { code: "station_error", status: 500 };
}

function parseBearerAuth(req: Request): { publicId: string; secret: string } | null {
  const header = req.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1]!;
  const sep = token.indexOf(":");
  if (sep <= 0) return null;
  return {
    publicId: token.slice(0, sep),
    secret: token.slice(sep + 1),
  };
}

async function requireStation(req: Request) {
  const auth = parseBearerAuth(req);
  if (!auth) throw Object.assign(new Error("missing_station_auth"), { status: 401 });
  try {
    return await verifyStationCredentials(auth.publicId, auth.secret);
  } catch (err) {
    const message = err instanceof Error ? err.message : "station_auth_failed";
    const mapped = mapStationRpcError(message);
    // Conserva el status mapejat (p. ex. 404 station_not_found), no forçar 401 genèric
    throw Object.assign(new Error(message), { status: mapped.status });
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/station-api\/?/, "").replace(/^\//, "");

  try {
    if (req.method === "GET" && (path === "health" || path === "")) {
      return jsonResponse({ ok: true, service: "station-api" });
    }

    if (req.method === "POST" && path === "register") {
      let body: {
        pairing_code?: string;
        local_pin?: string;
        name?: string;
        device_public_id?: string;
      };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.pairing_code) return errorResponse("missing_pairing_code", "pairing_code required");
      if (!body.local_pin || !isValidStationPin(body.local_pin)) {
        return errorResponse("invalid_local_pin", "PIN must be 4-6 digits");
      }

      try {
        await assertStationRegisterRateLimit(extractStationClientKey(req));
      } catch (err) {
        if (err instanceof StationRegisterRateLimitError) {
          if (err.detail) {
            await recordStationRateLimitBlock(err.detail);
          }
          return errorResponse(
            "station_register_rate_limited",
            "Too many pairing attempts. Try again later.",
            429,
            { retry_after_seconds: err.retryAfterSeconds },
          );
        }
        throw err;
      }

      const devicePublicId = body.device_public_id?.trim() || generateDevicePublicId();
      const deviceSecret = generateDeviceSecret();

      const registered = await registerStationDevice({
        pairing_code: body.pairing_code,
        device_public_id: devicePublicId,
        device_secret: deviceSecret,
        local_pin: body.local_pin,
        name: body.name,
      });

      return jsonResponse({
        ...registered,
        device_secret: deviceSecret,
        device_public_id: devicePublicId,
      }, 201);
    }

    if (req.method === "GET" && path === "bootstrap") {
      const auth = parseBearerAuth(req);
      const station = await requireStation(req);
      const offlineEnabled = await isStationOfflineDeferredEnabled(station.tenant_id);
      return jsonResponse({
        device_id: station.device_id,
        device_public_id: auth?.publicId ?? null,
        name: station.name,
        display_title: station.display_title ?? null,
        display_logo_url: station.display_logo_url ?? null,
        effective_display_title: station.effective_display_title ?? station.name,
        status: station.status,
        location_id: station.location_id,
        location_path: station.location_path,
        site_id: station.site_id,
        allowed_methods: station.allowed_methods ?? ["manual"],
        geo_antifraud_enabled: station.geo_antifraud_enabled ?? false,
        geo_antifraud_radius_m: station.geo_antifraud_radius_m ?? 150,
        location_has_geo: station.location_has_geo ?? false,
        site_timezone: station.site_timezone ?? "Europe/Madrid",
        last_seen_at: station.last_seen_at ?? null,
        connectivity_status: station.connectivity_status ?? null,
        entry_mode: station.entry_mode ?? "employee_list",
        employee_list_layout: station.employee_list_layout ?? "compact",
        document_match: station.document_match ?? "suffix",
        document_suffix_length: station.document_suffix_length ?? 4,
        identity_confirm: station.identity_confirm ?? "none",
        qr_identity_confirm: station.qr_identity_confirm ?? "none",
        session_idle_seconds: station.session_idle_seconds ?? 60,
        session_return_countdown_seconds: station.session_return_countdown_seconds ?? 15,
        session_allow_history: station.session_allow_history ?? false,
        session_history_max_days: station.session_history_max_days ?? 90,
        ux_preset: station.ux_preset ?? "custom",
        waiting_idle_seconds: station.waiting_idle_seconds ?? 0,
        mask_names_on_waiting: station.mask_names_on_waiting ?? false,
        allow_unassigned_punch: station.allow_unassigned_punch ?? true,
        warn_unassigned_punch: station.warn_unassigned_punch ?? true,
        warn_wrong_scheduled_location: station.warn_wrong_scheduled_location ?? true,
        block_wrong_scheduled_location: station.block_wrong_scheduled_location ?? false,
        offline_deferred_punch_enabled: offlineEnabled,
        ops_lockdown: Boolean(station.ops_lockdown),
        config_version: Number(station.config_version ?? 1),
        ready: station.status === "active" && !!station.location_id && !station.ops_lockdown,
      });
    }

    if (req.method === "POST" && path === "heartbeat") {
      const auth = parseBearerAuth(req);
      if (!auth) {
        return errorResponse("missing_station_auth", "Station authentication required", 401);
      }
      let pendingCount: number | undefined;
      let quarantinedCount: number | undefined;
      try {
        const body = await req.json() as {
          pending_count?: number;
          quarantined_count?: number;
        };
        if (typeof body.pending_count === "number") pendingCount = body.pending_count;
        if (typeof body.quarantined_count === "number") quarantinedCount = body.quarantined_count;
      } catch {
        // empty body is fine
      }
      const health = await recordStationHeartbeat(auth.publicId, auth.secret, {
        pendingCount,
        quarantinedCount,
      });
      return jsonResponse(health);
    }

    if (req.method === "GET" && path === "employees") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }
      const payload = await listStationEmployees(station.device_id);
      return jsonResponse({
        location_path: station.location_path,
        ...payload,
      });
    }

    if (req.method === "GET" && path === "pause-configs") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }
      const payload = await listStationPauseConfigs(station.device_id);
      return jsonResponse(payload);
    }

    if (req.method === "POST" && path === "employee-location-hint") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }

      let body: { employee_id?: string };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.employee_id) {
        return errorResponse("missing_employee_id", "employee_id required");
      }

      const hint = await getStationEmployeeLocationHint(station.device_id, body.employee_id);
      return jsonResponse(hint);
    }

    if (req.method === "POST" && path === "verify-pin") {
      const station = await requireStation(req);

      let body: { local_pin?: string };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.local_pin || !isValidStationPin(body.local_pin)) {
        return errorResponse("invalid_local_pin", "PIN must be 4-6 digits", 400);
      }

      const result = await verifyStationLocalPin(station.device_id, body.local_pin);
      if (result.status === "ok") {
        return jsonResponse(result);
      }
      if (result.status === "locked") {
        return errorResponse(
          "station_pin_locked",
          "Too many failed PIN attempts",
          429,
          { retry_after_seconds: result.retry_after_seconds ?? 900 },
        );
      }
      return errorResponse(
        "station_pin_invalid",
        "Invalid local PIN",
        403,
        { pin_attempts: result.pin_attempts ?? null },
      );
    }

    if (req.method === "POST" && path === "verify-employee-pin") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }

      let body: { employee_id?: string; pin?: string };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.employee_id) {
        return errorResponse("missing_employee_id", "employee_id required");
      }
      if (!body.pin || typeof body.pin !== "string") {
        return errorResponse("missing_pin", "pin required");
      }

      const result = await verifyStationEmployeePin(
        station.device_id,
        body.employee_id,
        body.pin,
      );

      if (result.status === "ok") {
        return jsonResponse(result);
      }
      if (result.status === "no_pin") {
        return jsonResponse(result);
      }
      if (result.status === "locked") {
        return errorResponse(
          "station_employee_pin_locked",
          "Too many failed PIN attempts",
          429,
          { retry_after_seconds: result.retry_after_seconds ?? 900 },
        );
      }
      if (result.status === "invalid_format") {
        return errorResponse("invalid_pin_format", "PIN must be 4-6 digits", 400);
      }
      if (result.status === "employee_not_allowed") {
        return errorResponse("employee_not_allowed", "Employee not allowed at this station", 403);
      }
      return errorResponse(
        "station_employee_pin_invalid",
        "Invalid employee PIN",
        403,
        { pin_attempts: result.pin_attempts ?? null },
      );
    }

    if (req.method === "POST" && path === "employee-history") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }
      if (!(station.session_allow_history ?? false)) {
        return errorResponse("station_history_disabled", "History is disabled on this station", 409);
      }

      let body: { employee_id?: string; from?: string; to?: string; pin?: string };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.employee_id) {
        return errorResponse("missing_employee_id", "employee_id required");
      }
      if (!body.from || !body.to) {
        return errorResponse("missing_date_range", "from and to required (YYYY-MM-DD)");
      }
      if (!body.pin || typeof body.pin !== "string") {
        return errorResponse("missing_pin", "pin required to view history");
      }

      const pinResult = await verifyStationEmployeePin(
        station.device_id,
        body.employee_id,
        body.pin,
      );

      if (pinResult.status === "no_pin") {
        return errorResponse(
          "station_history_pin_required",
          "Employee portal PIN is required to view history",
          403,
        );
      }
      if (pinResult.status === "locked") {
        return errorResponse(
          "station_employee_pin_locked",
          "Too many failed PIN attempts",
          429,
          { retry_after_seconds: pinResult.retry_after_seconds ?? 900 },
        );
      }
      if (pinResult.status === "invalid_format") {
        return errorResponse("invalid_pin_format", "PIN must be 4-6 digits", 400);
      }
      if (pinResult.status === "employee_not_allowed") {
        return errorResponse("employee_not_allowed", "Employee not allowed at this station", 403);
      }
      if (pinResult.status !== "ok") {
        return errorResponse(
          "station_employee_pin_invalid",
          "Invalid employee PIN",
          403,
          { pin_attempts: pinResult.pin_attempts ?? null },
        );
      }

      const history = await getStationEmployeeHistory(
        station.device_id,
        body.employee_id,
        body.from,
        body.to,
      );
      return jsonResponse(history);
    }

    if (req.method === "POST" && path === "resolve-identity") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }

      const allowed = station.allowed_methods ?? ["manual"];
      if (!allowed.includes("qr") && !allowed.includes("barcode")) {
        return errorResponse("station_qr_not_allowed", "QR is not enabled for this station", 403);
      }

      let body: { token?: string };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.token?.trim()) {
        return errorResponse("missing_token", "token required");
      }

      const auth = parseBearerAuth(req);
      const clientKey = auth
        ? `device:${auth.publicId}:${extractStationClientKey(req)}`
        : extractStationClientKey(req);

      // ST-11: rate limit dins el RPC (un sol comptador). Edge passa clientKey.
      let result;
      try {
        result = await resolveAttendanceIdentityToken({
          token: body.token.trim(),
          device_public_id: auth!.publicId,
          client_key: clientKey,
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (msg.includes("station_identity_resolve_rate_limited")) {
          return errorResponse(
            "station_identity_resolve_rate_limited",
            "Too many QR resolve attempts. Try again later.",
            429,
          );
        }
        if (msg.includes("identity_token_entropy_too_low")) {
          return errorResponse(
            "identity_token_entropy_too_low",
            "Token rejected: insufficient entropy",
            400,
          );
        }
        throw err;
      }

      return jsonResponse(result);
    }

    if (req.method === "POST" && path === "resolve-employee-document") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }

      const allowed = station.allowed_methods ?? ["manual"];
      if (!allowed.includes("manual")) {
        return errorResponse(
          "station_manual_not_allowed",
          "Document/manual entry is not enabled for this station",
          403,
        );
      }

      let body: { document_id?: string };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.document_id || typeof body.document_id !== "string") {
        return errorResponse("missing_document_id", "document_id required");
      }

      const auth = parseBearerAuth(req);
      const clientKey = auth
        ? `doc:${auth.publicId}:${extractStationClientKey(req)}`
        : `doc:${extractStationClientKey(req)}`;

      try {
        await assertStationDocumentResolveRateLimit(clientKey);
      } catch (err) {
        if (err instanceof StationDocumentResolveRateLimitError) {
          if (err.detail) {
            await recordStationRateLimitBlock(err.detail);
          }
          return errorResponse(
            "station_document_resolve_rate_limited",
            "Too many document lookup attempts. Try again later.",
            429,
            { retry_after_seconds: err.retryAfterSeconds },
          );
        }
        throw err;
      }

      const result = await resolveStationEmployeeDocument(
        station.device_id,
        body.document_id,
      );

      // Anti-enumeration: keep 200 with status not_found (never 404 for miss).
      return jsonResponse(result);
    }

    if (req.method === "POST" && path === "punch") {
      const station = await requireStation(req);
      if (station.status !== "active" || !station.location_id) {
        return errorResponse("station_not_ready", "Station is not active or has no location assigned", 409);
      }
      if (station.ops_lockdown) {
        return errorResponse("station_ops_lockdown", "Station is in operational lockdown", 423);
      }

      let body: {
        employee_id?: string;
        punch_type?: string;
        client_op_id?: string;
        pause_type?: string;
        source?: string;
        device_geo?: Record<string, unknown>;
        identity_token?: string;
        occurred_at?: string;
      };
      try {
        body = await req.json();
      } catch {
        return errorResponse("invalid_json", "Invalid JSON body");
      }

      if (!body.employee_id) return errorResponse("missing_employee_id", "employee_id required");
      if (!body.punch_type) return errorResponse("missing_punch_type", "punch_type required");

      const punchSource = body.source === "qr" ? "qr" : "station";
      if (punchSource === "qr" && !body.identity_token?.trim()) {
        return errorResponse("identity_token_required", "identity_token required for QR punch", 409);
      }

      let occurredAt: string | null = null;
      if (typeof body.occurred_at === "string" && body.occurred_at.trim()) {
        const parsed = Date.parse(body.occurred_at);
        if (Number.isNaN(parsed)) {
          return errorResponse("invalid_occurred_at", "occurred_at must be ISO timestamptz");
        }
        occurredAt = new Date(parsed).toISOString();
      }

      const result = await recordStationPunch({
        device_id: station.device_id,
        employee_id: body.employee_id,
        client_op_id: body.client_op_id ?? generateClientOpId(),
        punch_type: body.punch_type,
        pause_type: body.pause_type ?? null,
        source: punchSource,
        device_geo: body.device_geo ?? null,
        identity_token: body.identity_token?.trim() ?? null,
        occurred_at: occurredAt,
      });

      return jsonResponse(result);
    }

    return errorResponse("not_found", "Route not found", 404);
  } catch (err) {
    const explicitStatus = typeof err === "object" && err && "status" in err
      ? Number((err as { status: number }).status)
      : null;
    const message = err instanceof Error ? err.message : "internal_error";
    const mapped = mapStationRpcError(message);
    const httpStatus = explicitStatus && explicitStatus >= 400 && explicitStatus < 600
      ? explicitStatus
      : mapped.status;
    // Sempre preferir el codi mapejat (evita "station_error" quan el missatge ja és conegut)
    return errorResponse(mapped.code, message, httpStatus);
  }
});

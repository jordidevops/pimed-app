/**
 * employee-portal-api — EP0 spike
 *
 * Public Edge Function (verify_jwt = false). Called server-to-server from
 * public-portal Next.js proxy — never directly from the browser.
 *
 * Routes:
 *   POST /session
 *   POST /session/refresh
 *   GET  /session/me
 *   POST /session/revoke-dev   (local only — spike testing)
 *   GET  /health
 */

import { corsHeaders } from "../_shared/cors.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { ensureDevTokenStore } from "../_shared/employee-portal/dev-token-store.ts";
import {
  createPortalSession,
  getPortalSessionMe,
  refreshPortalSession,
  revokePortalToken,
  SessionError,
} from "../_shared/employee-portal/session-service.ts";
import { changePortalPin, setupPortalPin } from "../_shared/employee-portal/pin-service.ts";
import { getPortalBootstrapState } from "../_shared/employee-portal/bootstrap-service.ts";
import {
  confirmPortalIdentity,
  rejectPortalIdentity,
  verifyPortalIdentity,
} from "../_shared/employee-portal/identity-service.ts";
import {
  consumePortalPinReset,
  validatePortalPinReset,
} from "../_shared/employee-portal/pin-reset-service.ts";
import { requirePortalSession, authorizePortalPunch } from "../_shared/employee-portal/require-session.ts";
import {
  getPortalToday,
  PunchError,
  recordPortalPunch,
  syncPortalPunches,
  type PortalPunchType,
} from "../_shared/employee-portal/punch-service.ts";
import {
  getPortalSchedule,
  ScheduleError,
} from "../_shared/employee-portal/schedule-service.ts";
import {
  getPortalMyShifts,
  MyShiftsError,
} from "../_shared/employee-portal/my-shifts-service.ts";
import {
  claimPortalShiftOpening,
  getPortalShiftOpenings,
  OpeningsError,
  withdrawPortalShiftOpeningClaim,
} from "../_shared/employee-portal/openings-service.ts";
import {
  getPortalShiftSwaps,
  requestPortalShiftSwap,
  SwapsError,
} from "../_shared/employee-portal/swaps-service.ts";
import {
  getPortalHistory,
  HistoryError,
} from "../_shared/employee-portal/history-service.ts";
import {
  confirmPortalMonthlyReport,
  confirmPortalPeriodReport,
  getPortalMonthlyReport,
  MonthlyReportError,
} from "../_shared/employee-portal/monthly-report-service.ts";
import { getPortalPauseConfigs, PauseError } from "../_shared/employee-portal/pause-service.ts";
import {
  getPortalAbsenceTypes,
  listPortalAbsences,
  requestPortalAbsence,
  AbsenceError,
} from "../_shared/employee-portal/absence-service.ts";
import {
  getPortalAccessLogs,
  AccessLogsError,
} from "../_shared/employee-portal/access-logs-service.ts";
import {
  getPortalVapidPublicKey,
  savePortalPushSubscription,
  PushError,
} from "../_shared/employee-portal/push-service.ts";
import {
  acknowledgePortalDocument,
  DocumentsError,
  listPortalDocuments,
} from "../_shared/employee-portal/documents-service.ts";
import {
  ContentError,
  getPortalContentBySlug,
  listPortalContent,
} from "../_shared/employee-portal/content-service.ts";
import { issuePortalAttendanceQrToken } from "../_shared/employee-portal/attendance-identity-service.ts";
import { StationIdentityIssueRateLimitError, recordStationRateLimitBlock } from "../_shared/attendance-station/rate-limit.ts";

const FEATURE = "employee-portal-api";
const USE_DEV_STUB = Deno.env.get("EMPLOYEE_PORTAL_USE_DEV_STUB") === "true";

const portalCorsHeaders = {
  ...corsHeaders,
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-tenant-id, x-employee-portal-session",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...portalCorsHeaders, "Content-Type": "application/json" },
  });
}

function jsonError(
  status: number,
  code: string,
  message?: string,
  extra?: Record<string, unknown>,
): Response {
  const body: Record<string, unknown> = { error: { code, message: message ?? code, ...extra } };
  const headers: Record<string, string> = {
    ...portalCorsHeaders,
    "Content-Type": "application/json",
  };
  if (typeof extra?.retry_after_seconds === "number") {
    headers["Retry-After"] = String(extra.retry_after_seconds);
  }
  return new Response(JSON.stringify(body), { status, headers });
}

function extractRoute(req: Request): string {
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const fnIndex = parts.lastIndexOf("employee-portal-api");
  const routeParts = fnIndex >= 0 ? parts.slice(fnIndex + 1) : parts;
  return routeParts.join("/");
}

function getBearerToken(req: Request): string | null {
  const auth = req.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim() || null;
}

function getSessionToken(req: Request): string | null {
  const headerToken = req.headers.get("X-Employee-Portal-Session");
  if (headerToken) return headerToken.trim() || null;
  return getBearerToken(req);
}

function assertProxyCaller(req: Request): void {
  const serviceKey =
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SERVICE_ROLE_KEY") ??
    "";
  if (!serviceKey) return;

  const auth = req.headers.get("Authorization");
  const apiKey = req.headers.get("apikey");
  const allowed =
    auth === `Bearer ${serviceKey}` || apiKey === serviceKey;
  if (!allowed) {
    throw new SessionError("unauthorized_proxy", 401, "Invalid proxy credentials");
  }
}

function isUuid(value: string): boolean {
  // Accepta UUID v1–v8 (incl. v7 per client_op_id estable EX-05.1)
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isIsoDate(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(value);
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: portalCorsHeaders });
  }

  const route = extractRoute(req);

  try {
    await ensureDevTokenStore();

    if (req.method === "GET" && (route === "" || route === "health")) {
      return json({
        status: "ok",
        feature: FEATURE,
        mode: USE_DEV_STUB ? "ep2-db+dev-stub" : "ep2-db",
      });
    }

    assertProxyCaller(req);

    if (req.method === "GET" && route === "bootstrap/state") {
      const url = new URL(req.url);
      const secret = url.searchParams.get("secret")?.trim() ?? "";
      if (!secret) {
        return jsonError(400, "missing_secret");
      }

      const state = await getPortalBootstrapState(secret);
      return json(state);
    }

    if (req.method === "GET" && route === "session/me") {
      const token = getSessionToken(req);
      if (!token) {
        return jsonError(401, "missing_session");
      }

      const session = await getPortalSessionMe(token);
      return json(session);
    }

    if (req.method === "POST" && route === "identity/qr-token") {
      const { record } = await requirePortalSession(getSessionToken(req));
      try {
        const issued = await issuePortalAttendanceQrToken(record.employee_id);
        return json(issued);
      } catch (err) {
        if (err instanceof StationIdentityIssueRateLimitError) {
          if (err.detail) {
            await recordStationRateLimitBlock(err.detail);
          }
          return jsonError(429, "station_identity_issue_rate_limited", undefined, {
            retry_after_seconds: err.retryAfterSeconds,
          });
        }
        const message = err instanceof Error ? err.message : "issue_qr_token_failed";
        if (message.includes("employee_not_found")) {
          return jsonError(404, "employee_not_found");
        }
        throw err;
      }
    }

    if (req.method === "GET" && route === "today") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const today = await getPortalToday(record.employee_id, record.tenant_id);
      return json(today);
    }

    if (req.method === "GET" && route === "schedule") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const url = new URL(req.url);
      const from = url.searchParams.get("from")?.trim() ?? "";
      const to = url.searchParams.get("to")?.trim() ?? "";

      if (!from || !to || !isIsoDate(from) || !isIsoDate(to)) {
        return jsonError(400, "missing_date_range");
      }

      const schedule = await getPortalSchedule(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        from,
        to,
      );
      return json(schedule);
    }

    if (req.method === "GET" && route === "shifts") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const url = new URL(req.url);
      const from = url.searchParams.get("from")?.trim() ?? "";
      const to = url.searchParams.get("to")?.trim() ?? "";

      if (!from || !to || !isIsoDate(from) || !isIsoDate(to)) {
        return jsonError(400, "missing_date_range");
      }

      const shifts = await getPortalMyShifts(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        from,
        to,
      );
      return json(shifts);
    }

    if (req.method === "GET" && route === "openings") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const url = new URL(req.url);
      const from = url.searchParams.get("from")?.trim() ?? "";
      const to = url.searchParams.get("to")?.trim() ?? "";

      if (!from || !to || !isIsoDate(from) || !isIsoDate(to)) {
        return jsonError(400, "missing_date_range");
      }

      const openings = await getPortalShiftOpenings(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        from,
        to,
      );
      return json(openings);
    }

    if (req.method === "GET" && route === "swaps") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const swaps = await getPortalShiftSwaps(
        record.employee_id,
        record.tenant_id,
        record.token_id,
      );
      return json(swaps);
    }

    if (req.method === "GET" && route === "history") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const url = new URL(req.url);
      const from = url.searchParams.get("from")?.trim() ?? "";
      const to = url.searchParams.get("to")?.trim() ?? "";

      if (!from || !to || !isIsoDate(from) || !isIsoDate(to)) {
        return jsonError(400, "missing_date_range");
      }

      const history = await getPortalHistory(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        from,
        to,
      );
      return json(history);
    }

    if (req.method === "GET" && route === "pause-configs") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const configs = await getPortalPauseConfigs(record.employee_id, record.tenant_id);
      return json({ configs });
    }

    if (req.method === "GET" && route === "absence-types") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const types = await getPortalAbsenceTypes(record.employee_id, record.tenant_id);
      return json({ types });
    }

    if (req.method === "GET" && route === "absences") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const absences = await listPortalAbsences(record.employee_id, record.tenant_id);
      return json({ absences });
    }

    if (req.method === "GET" && route === "access-logs") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const accessData = await getPortalAccessLogs(
        record.employee_id,
        record.tenant_id,
        record.token_id,
      );
      return json(accessData);
    }

    if (req.method === "GET" && route === "push/vapid-public-key") {
      await requirePortalSession(getSessionToken(req));
      const publicKey = getPortalVapidPublicKey();
      return json({ public_key: publicKey, enabled: Boolean(publicKey) });
    }

    if (req.method === "GET" && route === "documents") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const documents = await listPortalDocuments(
        record.employee_id,
        record.tenant_id,
        record.token_id,
      );
      return json(documents);
    }

    if (req.method === "GET" && route === "content") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const content = await listPortalContent(
        record.employee_id,
        record.tenant_id,
        record.token_id,
      );
      return json(content);
    }

    if (req.method === "GET" && route.startsWith("content/")) {
      const slug = decodeURIComponent(route.slice("content/".length)).trim();
      if (!slug) {
        return jsonError(404, "not_found");
      }

      const { record } = await requirePortalSession(getSessionToken(req));
      const item = await getPortalContentBySlug(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        slug,
      );
      return json(item);
    }

    if (req.method === "GET" && route === "monthly-report") {
      const { record } = await requirePortalSession(getSessionToken(req));
      const url = new URL(req.url);
      const yearRaw = url.searchParams.get("year")?.trim() ?? "";
      const monthRaw = url.searchParams.get("month")?.trim() ?? "";
      const periodFrom = url.searchParams.get("period_from")?.trim() || undefined;
      const periodTo = url.searchParams.get("period_to")?.trim() || undefined;
      const year = Number(yearRaw);
      const month = Number(monthRaw);

      if (!yearRaw || !monthRaw || !Number.isInteger(year) || !Number.isInteger(month)) {
        return jsonError(400, "missing_year_month");
      }

      const report = await getPortalMonthlyReport(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        year,
        month,
        periodFrom,
        periodTo,
      );
      return json(report);
    }

    if (req.method !== "POST") {
      return jsonError(405, "method_not_allowed");
    }

    if (route === "session") {
      let body: { secret?: string; pin?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }

      const session = await createPortalSession(
        body.secret.trim(),
        typeof body.pin === "string" ? body.pin : undefined,
      );
      return json(session);
    }

    if (route === "identity/verify") {
      let body: { secret?: string; document_id?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }
      if (!body.document_id || typeof body.document_id !== "string") {
        return jsonError(400, "missing_document_id");
      }

      const result = await verifyPortalIdentity(body.secret.trim(), body.document_id);
      return json(result);
    }

    if (route === "identity/confirm") {
      let body: { secret?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }

      const result = await confirmPortalIdentity(body.secret.trim());
      return json(result);
    }

    if (route === "identity/reject") {
      let body: { secret?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }

      await rejectPortalIdentity(body.secret.trim());
      return json({ ok: true });
    }

    if (route === "pin/setup") {
      let body: { secret?: string; pin?: string; confirm_pin?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }
      if (!body.pin || typeof body.pin !== "string") {
        return jsonError(400, "missing_pin");
      }
      if (!body.confirm_pin || typeof body.confirm_pin !== "string") {
        return jsonError(400, "missing_confirm_pin");
      }

      const session = await setupPortalPin(
        body.secret.trim(),
        body.pin,
        body.confirm_pin,
      );
      return json(session);
    }

    if (route === "pin/change") {
      const token = getSessionToken(req);
      if (!token) {
        return jsonError(401, "missing_session");
      }

      let body: { current_pin?: string; new_pin?: string; confirm_pin?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.current_pin || typeof body.current_pin !== "string") {
        return jsonError(400, "missing_current_pin");
      }
      if (!body.new_pin || typeof body.new_pin !== "string") {
        return jsonError(400, "missing_new_pin");
      }
      if (!body.confirm_pin || typeof body.confirm_pin !== "string") {
        return jsonError(400, "missing_confirm_pin");
      }

      const { record } = await requirePortalSession(token);
      await changePortalPin(
        record,
        body.current_pin,
        body.new_pin,
        body.confirm_pin,
      );
      return json({ ok: true });
    }

    if (route === "pin/reset/validate") {
      let body: { secret?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }

      const result = await validatePortalPinReset(body.secret.trim());
      return json(result);
    }

    if (route === "pin/reset/consume") {
      let body: { secret?: string; pin?: string; confirm_pin?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.secret || typeof body.secret !== "string") {
        return jsonError(400, "missing_secret");
      }
      if (!body.pin || typeof body.pin !== "string") {
        return jsonError(400, "missing_pin");
      }
      if (!body.confirm_pin || typeof body.confirm_pin !== "string") {
        return jsonError(400, "missing_confirm_pin");
      }

      const result = await consumePortalPinReset(
        body.secret.trim(),
        body.pin,
        body.confirm_pin,
      );
      return json(result);
    }

    if (route === "session/refresh") {
      const token = getSessionToken(req);
      if (!token) {
        return jsonError(401, "missing_session");
      }

      let body: { pin?: string } = {};
      try {
        const raw = await req.text();
        if (raw.trim()) {
          body = JSON.parse(raw) as { pin?: string };
        }
      } catch {
        return jsonError(400, "invalid_json");
      }

      const session = await refreshPortalSession(
        token,
        typeof body.pin === "string" ? body.pin : undefined,
      );
      return json(session);
    }

    if (route === "session/revoke-dev") {
      if (Deno.env.get("ENVIRONMENT") !== "local") {
        return jsonError(404, "not_found");
      }

      let body: { token_id?: string; compromised?: boolean };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!body.token_id) {
        return jsonError(400, "missing_token_id");
      }

      const ok = await revokePortalToken(body.token_id, Boolean(body.compromised));
      if (!ok) return jsonError(404, "token_not_found");
      return json({ revoked: true, token_id: body.token_id });
    }

    if (route === "punch/sync") {
      let body: {
        ops?: Array<{
          client_op_id?: string;
          punch_type?: string;
          occurred_at?: string;
          device_info?: Record<string, string>;
          pause_type?: string;
          pause_counts_as_work?: boolean;
        }>;
      };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      if (!Array.isArray(body.ops) || body.ops.length === 0) {
        return jsonError(400, "missing_ops");
      }
      if (body.ops.length > 25) {
        return jsonError(400, "batch_too_large");
      }

      const earliestOccurred = body.ops
        .map((op) => op.occurred_at)
        .filter((v): v is string => typeof v === "string" && v.length > 0)
        .sort()[0];

      const { record } = await authorizePortalPunch(
        getSessionToken(req),
        earliestOccurred,
      );

      const VALID_PUNCH_TYPES = new Set([
        "in", "out", "break_start", "break_end",
        "day_start", "day_end", "travel_start", "travel_end",
      ]);

      const ops: Array<{
        client_op_id: string;
        punch_type: PortalPunchType;
        occurred_at: string;
        device_info: Record<string, string> | null;
        pause_type: string | null;
        pause_counts_as_work: boolean | null;
      }> = [];
      for (const op of body.ops) {
        if (!op.client_op_id || !isUuid(op.client_op_id)) {
          return jsonError(400, "missing_client_op_id");
        }
        if (!op.punch_type || !VALID_PUNCH_TYPES.has(op.punch_type)) {
          return jsonError(400, "invalid_punch_type");
        }
        if (
          (op.punch_type === "break_start" || op.punch_type === "break_end") &&
          (!op.pause_type || typeof op.pause_type !== "string")
        ) {
          return jsonError(400, "missing_pause_type");
        }
        if (!op.occurred_at || typeof op.occurred_at !== "string") {
          return jsonError(400, "missing_occurred_at");
        }
        ops.push({
          client_op_id: op.client_op_id,
          punch_type: op.punch_type as PortalPunchType,
          occurred_at: op.occurred_at,
          device_info: op.device_info ?? null,
          pause_type: op.pause_type ?? null,
          pause_counts_as_work: op.pause_counts_as_work ?? null,
        });
      }

      const results = await syncPortalPunches({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        ops,
      });

      return json({ results });
    }

    if (route === "punch") {
      let body: {
        client_op_id?: string;
        punch_type?: string;
        occurred_at?: string;
        device_info?: Record<string, string>;
        pause_type?: string;
        pause_counts_as_work?: boolean;
      };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await authorizePortalPunch(
        getSessionToken(req),
        body.occurred_at,
      );

      if (!body.client_op_id || !isUuid(body.client_op_id)) {
        return jsonError(400, "missing_client_op_id");
      }

      const VALID_PUNCH_TYPES = new Set([
        "in", "out", "break_start", "break_end",
        "day_start", "day_end", "travel_start", "travel_end",
      ]);

      if (!body.punch_type || !VALID_PUNCH_TYPES.has(body.punch_type)) {
        return jsonError(400, "invalid_punch_type");
      }

      if (
        (body.punch_type === "break_start" || body.punch_type === "break_end") &&
        (!body.pause_type || typeof body.pause_type !== "string")
      ) {
        return jsonError(400, "missing_pause_type");
      }

      const result = await recordPortalPunch({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        client_op_id: body.client_op_id,
        punch_type: body.punch_type as PortalPunchType,
        occurred_at: body.occurred_at,
        device_info: body.device_info ?? null,
        pause_type: body.pause_type ?? null,
        pause_counts_as_work: body.pause_counts_as_work ?? null,
      });

      return json(result);
    }

    if (route === "absences/request") {
      let body: {
        absence_type?: string;
        start_date?: string;
        end_date?: string;
        notes?: string;
        partial_start_time?: string;
        partial_end_time?: string;
      };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));

      if (!body.absence_type || !body.start_date || !body.end_date) {
        return jsonError(400, "missing_absence_fields");
      }
      if (!isIsoDate(body.start_date) || !isIsoDate(body.end_date)) {
        return jsonError(400, "invalid_date_range");
      }

      const result = await requestPortalAbsence({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        absence_type: body.absence_type,
        start_date: body.start_date,
        end_date: body.end_date,
        notes: body.notes ?? null,
        partial_start_time: body.partial_start_time ?? null,
        partial_end_time: body.partial_end_time ?? null,
      });
      return json(result);
    }

    if (route === "openings/claim") {
      let body: { opening_id?: string; notes?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));
      if (!body.opening_id || !isUuid(body.opening_id)) {
        return jsonError(400, "missing_opening_id");
      }

      const result = await claimPortalShiftOpening({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        opening_id: body.opening_id,
        notes: body.notes ?? null,
      });
      return json(result);
    }

    if (route === "openings/withdraw") {
      let body: { claim_id?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));
      if (!body.claim_id || !isUuid(body.claim_id)) {
        return jsonError(400, "missing_claim_id");
      }

      const result = await withdrawPortalShiftOpeningClaim({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        claim_id: body.claim_id,
      });
      return json(result);
    }

    if (route === "swaps/request") {
      let body: {
        requester_slot_id?: string;
        kind?: string;
        notes?: string;
        target_employee_id?: string;
      };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));
      if (!body.requester_slot_id || !isUuid(body.requester_slot_id)) {
        return jsonError(400, "missing_slot_id");
      }
      if (body.kind !== "give_away" && body.kind !== "call_off") {
        return jsonError(400, "invalid_kind");
      }

      const result = await requestPortalShiftSwap({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        requester_slot_id: body.requester_slot_id,
        kind: body.kind,
        notes: body.notes ?? null,
        target_employee_id: body.target_employee_id && isUuid(body.target_employee_id)
          ? body.target_employee_id
          : null,
      });
      return json(result);
    }

    if (route === "push/subscribe") {
      let body: { endpoint?: string; keys?: { p256dh?: string; auth?: string } };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));

      if (!body.endpoint || !body.keys?.p256dh || !body.keys?.auth) {
        return jsonError(400, "missing_push_subscription");
      }

      const result = await savePortalPushSubscription({
        employee_id: record.employee_id,
        tenant_id: record.tenant_id,
        token_id: record.token_id,
        endpoint: body.endpoint,
        p256dh: body.keys.p256dh,
        auth: body.keys.auth,
        user_agent: req.headers.get("user-agent"),
      });
      return json(result);
    }

    if (route === "documents/acknowledge") {
      let body: { assignment_id?: string };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));

      if (!body.assignment_id || !isUuid(body.assignment_id)) {
        return jsonError(400, "missing_assignment_id");
      }

      const result = await acknowledgePortalDocument(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        body.assignment_id,
      );
      return json(result);
    }

    if (route === "monthly-report/confirm") {
      let body: {
        year?: number;
        month?: number;
        period_from?: string;
        period_to?: string;
        calendar_year?: number;
        calendar_month?: number;
      };
      try {
        body = await req.json();
      } catch {
        return jsonError(400, "invalid_json");
      }

      const { record } = await requirePortalSession(getSessionToken(req));

      if (body.period_from && body.period_to) {
        const calendarYear = Number(body.calendar_year ?? body.year);
        const calendarMonth = Number(body.calendar_month ?? body.month);
        if (
          !Number.isInteger(calendarYear) ||
          !Number.isInteger(calendarMonth) ||
          calendarMonth < 1 ||
          calendarMonth > 12
        ) {
          return jsonError(400, "missing_calendar_month");
        }

        const result = await confirmPortalPeriodReport(
          record.employee_id,
          record.tenant_id,
          record.token_id,
          body.period_from,
          body.period_to,
          calendarYear,
          calendarMonth,
        );
        return json(result);
      }

      const year = Number(body.year);
      const month = Number(body.month);

      if (!Number.isInteger(year) || !Number.isInteger(month)) {
        return jsonError(400, "missing_year_month");
      }

      const result = await confirmPortalMonthlyReport(
        record.employee_id,
        record.tenant_id,
        record.token_id,
        year,
        month,
      );
      return json(result);
    }

    return jsonError(404, "not_found");
  } catch (err) {
    if (err instanceof SessionError) {
      if (
        (err.code === "pin_locked" || err.code === "identity_locked") &&
        err.retryAfterSeconds
      ) {
        return jsonError(err.status, err.code, err.message, {
          retry_after_seconds: err.retryAfterSeconds,
        });
      }
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof PunchError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof ScheduleError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof MyShiftsError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof OpeningsError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof SwapsError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof HistoryError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof MonthlyReportError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof PauseError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof AbsenceError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof AccessLogsError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof PushError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof DocumentsError) {
      return jsonError(err.status, err.code, err.message);
    }
    if (err instanceof ContentError) {
      return jsonError(err.status, err.code, err.message);
    }

    const message = err instanceof Error ? err.message : "unknown_error";
    log("error", FEATURE, "Unhandled error", { extra: { route, error: message } });
    captureException(err, { feature: FEATURE, extra: { route } });
    return jsonError(500, "internal_error");
  }
});

/**
 * Employee Portal API proxy — EP0
 *
 * Browser → /portal/api/* (rewritten via proxy.ts; cookie Path=/portal) → Edge Function.
 * Sets HttpOnly session cookie on the portal host (Path=/portal, no Domain).
 */

import { NextRequest, NextResponse } from "next/server";
import { callEmployeePortalApi } from "@/lib/employee-portal/proxy";
import {
  clearEmployeePortalSessionCookie,
  readEmployeePortalSessionCookie,
  setEmployeePortalSessionCookie,
} from "@/lib/employee-portal/cookie";
import type { PortalSessionPayload } from "@/lib/employee-portal/proxy";

function isSecureRequest(req: NextRequest): boolean {
  if (process.env.NODE_ENV === "production") return true;
  const forwarded = req.headers.get("x-forwarded-proto");
  return forwarded === "https";
}

type RouteParams = { path: string[] };

function shouldClearPortalSession(errorCode: string | undefined): boolean {
  return errorCode === "token_revoked" || errorCode === "token_invalid";
}

function buildProxyErrorResponse(
  result: {
    status: number;
    error: { code?: string; message?: string; retry_after_seconds?: number };
  },
  secure: boolean,
  clearSession = false,
): NextResponse {
  const response = NextResponse.json(
    {
      error: {
        code: result.error.code,
        message: result.error.message,
        retry_after_seconds: result.error.retry_after_seconds,
      },
    },
    { status: result.status },
  );
  if (typeof result.error.retry_after_seconds === "number") {
    response.headers.set("Retry-After", String(result.error.retry_after_seconds));
  }
  if (clearSession && shouldClearPortalSession(result.error.code)) {
    clearEmployeePortalSessionCookie(response, secure);
  }
  return response;
}

async function handlePost(
  req: NextRequest,
  pathSegments: string[],
): Promise<NextResponse> {
  const secure = isSecureRequest(req);
  const route = pathSegments.join("/");

  if (route === "session") {
    let body: { secret?: string; pin?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret) {
      return NextResponse.json({ error: { code: "missing_secret" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<PortalSessionPayload>("session", {
      body: {
        secret: body.secret,
        ...(body.pin ? { pin: body.pin } : {}),
      },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    const response = NextResponse.json({
      employee: result.data.employee,
      expires_in: result.data.expires_in,
      portal_policy: result.data.portal_policy,
    });
    setEmployeePortalSessionCookie(
      response,
      result.data.session_token,
      result.data.expires_in,
      secure,
    );
    return response;
  }

  if (route === "pin/setup") {
    let body: { secret?: string; pin?: string; confirm_pin?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret || !body.pin || !body.confirm_pin) {
      return NextResponse.json({ error: { code: "missing_fields" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<PortalSessionPayload>("pin/setup", {
      body: {
        secret: body.secret,
        pin: body.pin,
        confirm_pin: body.confirm_pin,
      },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    const response = NextResponse.json({
      employee: result.data.employee,
      expires_in: result.data.expires_in,
      portal_policy: result.data.portal_policy,
    });
    setEmployeePortalSessionCookie(
      response,
      result.data.session_token,
      result.data.expires_in,
      secure,
    );
    return response;
  }

  if (route === "pin/change") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    let body: { current_pin?: string; new_pin?: string; confirm_pin?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.current_pin || !body.new_pin || !body.confirm_pin) {
      return NextResponse.json({ error: { code: "missing_fields" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ ok: true }>("pin/change", {
      sessionToken,
      body,
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure, true);
    }

    return NextResponse.json(result.data);
  }

  if (route === "session/refresh") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    let body: { pin?: string } = {};
    try {
      const raw = await req.text();
      if (raw.trim()) {
        body = JSON.parse(raw) as { pin?: string };
      }
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<PortalSessionPayload>("session/refresh", {
      sessionToken,
      body: body.pin ? { pin: body.pin } : undefined,
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure, true);
    }

    const response = NextResponse.json({
      employee: result.data.employee,
      expires_in: result.data.expires_in,
      portal_policy: result.data.portal_policy,
    });
    setEmployeePortalSessionCookie(
      response,
      result.data.session_token,
      result.data.expires_in,
      secure,
    );
    return response;
  }

  if (route === "session/logout") {
    const response = NextResponse.json({ ok: true });
    clearEmployeePortalSessionCookie(response, secure);
    return response;
  }

  if (route === "session/revoke-dev") {
    if (process.env.NODE_ENV === "production") {
      return NextResponse.json({ error: { code: "not_found" } }, { status: 404 });
    }

    let body: { token_id?: string; compromised?: boolean };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ revoked: boolean }>("session/revoke-dev", {
      body,
    });

    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: result.status });
    }

    return NextResponse.json(result.data);
  }

  if (route === "punch") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

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
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{
      punch_id: string;
      status: string;
      anomaly_codes: string[];
    }>("punch", {
      sessionToken,
      body,
    });

    if (!result.ok) {
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "monthly-report/confirm") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    let body: { year?: number; month?: number };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ report_id: string }>("monthly-report/confirm", {
      sessionToken,
      body,
    });

    if (!result.ok) {
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "absences/request") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi("absences/request", { sessionToken, body });
    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }
    return NextResponse.json(result.data);
  }

  if (route === "push/subscribe") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi("push/subscribe", { sessionToken, body });
    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }
    return NextResponse.json(result.data);
  }

  if (route === "documents/acknowledge") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    let body: { assignment_id?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ acknowledged_at: string }>("documents/acknowledge", {
      sessionToken,
      body,
    });

    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "identity/qr-token") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const result = await callEmployeePortalApi<{
      token_id: string;
      token: string;
      method: string;
      expires_at: string;
      ttl_seconds: number;
    }>("identity/qr-token", {
      sessionToken,
    });

    if (!result.ok) {
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "identity/verify") {
    let body: { secret?: string; document_id?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret || !body.document_id) {
      return NextResponse.json({ error: { code: "missing_fields" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ full_name: string }>("identity/verify", {
      body: {
        secret: body.secret,
        document_id: body.document_id,
      },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    return NextResponse.json(result.data);
  }

  if (route === "identity/confirm") {
    let body: { secret?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret) {
      return NextResponse.json({ error: { code: "missing_secret" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{
      next: "pin_setup" | "pin" | "ready";
      full_name: string;
    }>("identity/confirm", {
      body: { secret: body.secret },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    return NextResponse.json(result.data);
  }

  if (route === "identity/reject") {
    let body: { secret?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret) {
      return NextResponse.json({ error: { code: "missing_secret" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ ok: true }>("identity/reject", {
      body: { secret: body.secret },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    return NextResponse.json(result.data);
  }

  if (route === "pin/reset/validate") {
    let body: { secret?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret) {
      return NextResponse.json({ error: { code: "missing_secret" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{
      valid: boolean;
      employee_name: string;
      expires_at: string;
    }>("pin/reset/validate", {
      body: { secret: body.secret },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    return NextResponse.json(result.data);
  }

  if (route === "pin/reset/consume") {
    let body: { secret?: string; pin?: string; confirm_pin?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.secret || !body.pin || !body.confirm_pin) {
      return NextResponse.json({ error: { code: "missing_fields" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{ employee_name: string }>("pin/reset/consume", {
      body: {
        secret: body.secret,
        pin: body.pin,
        confirm_pin: body.confirm_pin,
      },
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    return NextResponse.json(result.data);
  }

  return NextResponse.json({ error: { code: "not_found" } }, { status: 404 });
}

async function handleGet(
  req: NextRequest,
  pathSegments: string[],
): Promise<NextResponse> {
  const route = pathSegments.join("/");

  if (route === "session/me") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const secure = isSecureRequest(req);
    const result = await callEmployeePortalApi<PortalSessionPayload>("session/me", {
      method: "GET",
      sessionToken,
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure, true);
    }

    const response = NextResponse.json({
      employee: result.data.employee,
      portal_policy: result.data.portal_policy,
      expires_in: result.data.expires_in,
    });
    setEmployeePortalSessionCookie(
      response,
      result.data.session_token,
      result.data.expires_in,
      secure,
    );
    return response;
  }

  if (route === "health") {
    const result = await callEmployeePortalApi<{ status: string }>("health", {
      method: "GET",
    });
    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: result.status });
    }
    return NextResponse.json(result.data);
  }

  if (route === "bootstrap/state") {
    const secret = req.nextUrl.searchParams.get("secret")?.trim() ?? "";
    if (!secret) {
      return NextResponse.json({ error: { code: "missing_secret" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi<{
      state: string;
      full_name?: string;
      identity_locked?: boolean;
      retry_after_seconds?: number;
    }>(`bootstrap/state?secret=${encodeURIComponent(secret)}`, {
      method: "GET",
    });

    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: result.status });
    }

    return NextResponse.json(result.data);
  }

  if (route === "today") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const result = await callEmployeePortalApi("today", {
      method: "GET",
      sessionToken,
    });

    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "schedule") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const from = req.nextUrl.searchParams.get("from");
    const to = req.nextUrl.searchParams.get("to");
    if (!from || !to) {
      return NextResponse.json({ error: { code: "missing_date_range" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi(
      `schedule?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
      {
        method: "GET",
        sessionToken,
      },
    );

    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "shifts") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const from = req.nextUrl.searchParams.get("from");
    const to = req.nextUrl.searchParams.get("to");
    if (!from || !to) {
      return NextResponse.json({ error: { code: "missing_date_range" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi(
      `shifts?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
      {
        method: "GET",
        sessionToken,
      },
    );

    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "history") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const from = req.nextUrl.searchParams.get("from");
    const to = req.nextUrl.searchParams.get("to");
    if (!from || !to) {
      return NextResponse.json({ error: { code: "missing_date_range" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi(
      `history?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
      {
        method: "GET",
        sessionToken,
      },
    );

    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "monthly-report") {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const year = req.nextUrl.searchParams.get("year");
    const month = req.nextUrl.searchParams.get("month");
    if (!year || !month) {
      return NextResponse.json({ error: { code: "missing_year_month" } }, { status: 400 });
    }

    const result = await callEmployeePortalApi(
      `monthly-report?year=${encodeURIComponent(year)}&month=${encodeURIComponent(month)}`,
      { method: "GET", sessionToken },
    );

    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  if (route === "content" || route.startsWith("content/")) {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const result = await callEmployeePortalApi(route, { method: "GET", sessionToken });
    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  const sessionGetRoutes = [
    "documents",
    "pause-configs",
    "absence-types",
    "absences",
    "access-logs",
    "push/vapid-public-key",
  ] as const;

  if (sessionGetRoutes.includes(route as (typeof sessionGetRoutes)[number])) {
    const sessionToken = readEmployeePortalSessionCookie(req.headers.get("cookie"));
    if (!sessionToken) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const result = await callEmployeePortalApi(route, { method: "GET", sessionToken });
    if (!result.ok) {
      const secure = isSecureRequest(req);
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (shouldClearPortalSession(result.error?.code)) {
        clearEmployeePortalSessionCookie(response, secure);
      }
      return response;
    }
    return NextResponse.json(result.data);
  }

  return NextResponse.json({ error: { code: "not_found" } }, { status: 404 });
}

export async function POST(
  req: NextRequest,
  context: { params: Promise<RouteParams> },
): Promise<NextResponse> {
  const { path } = await context.params;
  return handlePost(req, path);
}

export async function GET(
  req: NextRequest,
  context: { params: Promise<RouteParams> },
): Promise<NextResponse> {
  const { path } = await context.params;
  return handleGet(req, path);
}

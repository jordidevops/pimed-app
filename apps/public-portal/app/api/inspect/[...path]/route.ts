import { NextRequest, NextResponse } from "next/server";
import {
  buildInspectAuthHeaderValue,
  clearInspectAuthCookie,
  readInspectAuthCookie,
  setInspectAuthCookie,
} from "@/lib/inspection-access/cookie";
import { callInspectApi } from "@/lib/inspection-access/proxy";

type RouteParams = { path: string[] };

/** Sliding session cap (12h) regardless of the link TTL. */
const INSPECT_SESSION_MAX_AGE_SECONDS = 12 * 60 * 60;

function isSecureRequest(req: NextRequest): boolean {
  if (process.env.NODE_ENV === "production") return true;
  return req.headers.get("x-forwarded-proto") === "https";
}

function extractClientIp(req: NextRequest): string | null {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip")?.trim() ??
    req.headers.get("cf-connecting-ip")?.trim() ??
    null
  );
}

function cookieMaxAge(expiresAt: string | null | undefined): number {
  if (!expiresAt) return INSPECT_SESSION_MAX_AGE_SECONDS;
  const remaining = Math.floor((new Date(expiresAt).getTime() - Date.now()) / 1000);
  if (!Number.isFinite(remaining) || remaining <= 0) {
    return INSPECT_SESSION_MAX_AGE_SECONDS;
  }
  return Math.min(remaining, INSPECT_SESSION_MAX_AGE_SECONDS);
}

async function handlePost(req: NextRequest, pathSegments: string[]): Promise<NextResponse> {
  const secure = isSecureRequest(req);
  const route = pathSegments.join("/");
  const clientIp = extractClientIp(req);

  if (route === "session") {
    let body: { link_id?: string; secret?: string };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const linkId = body.link_id?.trim() ?? "";
    const secret = body.secret?.trim() ?? "";
    if (!linkId || !secret) {
      return NextResponse.json({ error: { code: "missing_fields" } }, { status: 400 });
    }

    const result = await callInspectApi<{ ok: boolean; expires_at: string | null }>("session", {
      method: "POST",
      body: { link_id: linkId, secret },
      clientIp,
    });

    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: result.status });
    }

    const response = NextResponse.json({ ok: true, expires_at: result.data.expires_at });
    setInspectAuthCookie(response, linkId, secret, cookieMaxAge(result.data.expires_at), secure);
    return response;
  }

  if (route === "logout") {
    const response = NextResponse.json({ ok: true });
    clearInspectAuthCookie(response, secure);
    return response;
  }

  return NextResponse.json({ error: { code: "not_found" } }, { status: 404 });
}

async function handleGet(req: NextRequest, pathSegments: string[]): Promise<NextResponse> {
  const secure = isSecureRequest(req);
  const route = pathSegments.join("/");
  const clientIp = extractClientIp(req);

  if (route === "health") {
    const result = await callInspectApi<{ ok: boolean }>("health", { method: "GET", clientIp });
    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: result.status });
    }
    return NextResponse.json(result.data);
  }

  if (route === "data") {
    const auth = readInspectAuthCookie(req.headers.get("cookie"));
    if (!auth) {
      return NextResponse.json({ error: { code: "missing_session" } }, { status: 401 });
    }

    const params = new URLSearchParams();
    for (const key of ["punches_offset", "punches_limit", "summaries_offset", "summaries_limit"]) {
      const value = req.nextUrl.searchParams.get(key);
      if (value) params.set(key, value);
    }
    const query = params.toString();

    const result = await callInspectApi<Record<string, unknown>>(
      query ? `data?${query}` : "data",
      {
        method: "GET",
        inspectAuth: buildInspectAuthHeaderValue(auth),
        clientIp,
        userAgent: req.headers.get("user-agent"),
      },
    );

    if (!result.ok) {
      const response = NextResponse.json({ error: result.error }, { status: result.status });
      if (result.status === 404 || result.status === 401) {
        clearInspectAuthCookie(response, secure);
      }
      return response;
    }

    return NextResponse.json(result.data);
  }

  return NextResponse.json({ error: { code: "not_found" } }, { status: 404 });
}

export async function GET(req: NextRequest, ctx: { params: Promise<RouteParams> }) {
  const { path } = await ctx.params;
  return handleGet(req, path);
}

export async function POST(req: NextRequest, ctx: { params: Promise<RouteParams> }) {
  const { path } = await ctx.params;
  return handlePost(req, path);
}

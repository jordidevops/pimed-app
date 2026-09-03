import { NextRequest, NextResponse } from "next/server";
import {
  buildStationAuthorizationHeader,
  clearStationAuthCookie,
  readStationAuthCookie,
  setStationAuthCookie,
  shouldClearStationAuth,
} from "@/lib/attendance-station/cookie";
import { callStationApi } from "@/lib/attendance-station/proxy";

type RouteParams = { path: string[] };

function isSecureRequest(req: NextRequest): boolean {
  if (process.env.NODE_ENV === "production") return true;
  return req.headers.get("x-forwarded-proto") === "https";
}

function extractClientIp(req: NextRequest): string | null {
  return req.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
    ?? req.headers.get("x-real-ip")?.trim()
    ?? req.headers.get("cf-connecting-ip")?.trim()
    ?? null;
}

function buildProxyErrorResponse(
  result: {
    status: number;
    error: { code?: string; message?: string; retry_after_seconds?: number };
  },
  secure: boolean,
  clearAuth = false,
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
  if (clearAuth && shouldClearStationAuth(result.error.code, result.error.message)) {
    clearStationAuthCookie(response, secure);
  }
  return response;
}

async function handlePost(req: NextRequest, pathSegments: string[]): Promise<NextResponse> {
  const secure = isSecureRequest(req);
  const route = pathSegments.join("/");
  const clientIp = extractClientIp(req);

  if (route === "register") {
    let body: {
      pairing_code?: string;
      local_pin?: string;
      name?: string;
      device_public_id?: string;
    };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    const result = await callStationApi<{
      device_id: string;
      device_public_id: string;
      device_secret: string;
      status: string;
    }>("register", {
      method: "POST",
      body,
      clientIp,
    });

    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }

    const response = NextResponse.json(
      {
        device_id: result.data.device_id,
        device_public_id: result.data.device_public_id,
        status: result.data.status,
      },
      { status: result.status },
    );
    setStationAuthCookie(
      response,
      result.data.device_public_id,
      result.data.device_secret,
      secure,
    );
    return response;
  }

  if (route === "session/migrate") {
    let body: {
      device_id?: string;
      device_public_id?: string;
      device_secret?: string;
    };
    try {
      body = await req.json();
    } catch {
      return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
    }

    if (!body.device_public_id?.trim() || !body.device_secret?.trim()) {
      return NextResponse.json({ error: { code: "missing_station_credentials" } }, { status: 400 });
    }

    const authorization = buildStationAuthorizationHeader({
      publicId: body.device_public_id.trim(),
      secret: body.device_secret.trim(),
    });

    const verify = await callStationApi<{ device_id: string; status: string }>("bootstrap", {
      method: "GET",
      authorization,
      clientIp,
    });

    if (!verify.ok) {
      return buildProxyErrorResponse(verify, secure);
    }

    const response = NextResponse.json({
      device_id: verify.data.device_id ?? body.device_id ?? null,
      device_public_id: body.device_public_id.trim(),
      status: verify.data.status,
      migrated: true,
    });
    setStationAuthCookie(response, body.device_public_id.trim(), body.device_secret.trim(), secure);
    return response;
  }

  if (route === "session/logout") {
    const response = NextResponse.json({ ok: true });
    clearStationAuthCookie(response, secure);
    return response;
  }

  const auth = readStationAuthCookie(req.headers.get("cookie"));
  if (!auth) {
    return NextResponse.json({ error: { code: "missing_station_auth" } }, { status: 401 });
  }

  let body: unknown = {};
  try {
    const rawBody = await req.text();
    if (rawBody.trim()) {
      body = JSON.parse(rawBody);
    }
  } catch {
    return NextResponse.json({ error: { code: "invalid_json" } }, { status: 400 });
  }

  const result = await callStationApi<Record<string, unknown>>(route, {
    method: "POST",
    body,
    authorization: buildStationAuthorizationHeader(auth),
    clientIp,
  });

  if (!result.ok) {
    return buildProxyErrorResponse(result, secure, true);
  }

  return NextResponse.json(result.data, { status: result.status });
}

async function handleGet(req: NextRequest, pathSegments: string[]): Promise<NextResponse> {
  const secure = isSecureRequest(req);
  const route = pathSegments.join("/");
  const clientIp = extractClientIp(req);

  if (route === "health") {
    const result = await callStationApi<{ ok: boolean }>("health", { method: "GET", clientIp });
    if (!result.ok) {
      return buildProxyErrorResponse(result, secure);
    }
    return NextResponse.json(result.data);
  }

  const auth = readStationAuthCookie(req.headers.get("cookie"));
  if (!auth) {
    return NextResponse.json({ error: { code: "missing_station_auth" } }, { status: 401 });
  }

  const result = await callStationApi<Record<string, unknown>>(route, {
    method: "GET",
    authorization: buildStationAuthorizationHeader(auth),
    clientIp,
  });

  if (!result.ok) {
    return buildProxyErrorResponse(result, secure, true);
  }

  return NextResponse.json(result.data, { status: result.status });
}

export async function GET(req: NextRequest, ctx: { params: Promise<RouteParams> }) {
  const { path } = await ctx.params;
  return handleGet(req, path);
}

export async function POST(req: NextRequest, ctx: { params: Promise<RouteParams> }) {
  const { path } = await ctx.params;
  return handlePost(req, path);
}

/**
 * inspect-api — EX-09.2
 *
 * Public Edge Function (verify_jwt = false). Called server-to-server from the
 * public-portal Next.js proxy — never directly from the browser.
 *
 * Auth model: opaque share link (id + secret). The secret is exchanged once via
 * POST /session; the public-portal proxy then stores it in an HttpOnly cookie
 * and forwards it as `Authorization: Bearer {link_id}:{secret}` on later calls.
 *
 * Routes:
 *   POST /session  { link_id, secret }              → { ok, expires_at }
 *   GET  /data?punches_offset&punches_limit&...      → scoped inspection payload
 *   GET  /health
 *
 * Security:
 *   - Uniform 404 for invalid / expired / revoked links (no existence leak).
 *   - Rate limit per IP: 20 attempts / 15 min.
 *   - Resolve/peek only via service_role + secret (RPCs GRANTed to service_role).
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "inspect-api";

const inspectCorsHeaders = {
  ...corsHeaders,
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-tenant-id",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

// -----------------------------------------------------------------------------
// Rate limit (in-memory, per instance): 20 attempts / 15 min / IP
// -----------------------------------------------------------------------------
const RATE_LIMIT_MAX = 20;
const RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000;
const rateBuckets = new Map<string, number[]>();

function isRateLimited(key: string): boolean {
  const now = Date.now();
  const cutoff = now - RATE_LIMIT_WINDOW_MS;
  const hits = (rateBuckets.get(key) ?? []).filter((ts) => ts > cutoff);
  hits.push(now);
  rateBuckets.set(key, hits);
  // Opportunistic cleanup to bound memory.
  if (rateBuckets.size > 5000) {
    for (const [k, v] of rateBuckets) {
      if (v.every((ts) => ts <= cutoff)) rateBuckets.delete(k);
    }
  }
  return hits.length > RATE_LIMIT_MAX;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...inspectCorsHeaders, "Content-Type": "application/json" },
  });
}

function notFound(): Response {
  // Uniform response for invalid / expired / revoked / not found.
  return json({ error: { code: "not_found", message: "not_found" } }, 404);
}

function extractRoute(req: Request): string {
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const fnIndex = parts.lastIndexOf("inspect-api");
  const routeParts = fnIndex >= 0 ? parts.slice(fnIndex + 1) : parts;
  return routeParts.join("/");
}

function clientIp(req: Request): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip")?.trim() ??
    req.headers.get("cf-connecting-ip")?.trim() ??
    "unknown"
  );
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function parseInspectAuth(req: Request): { linkId: string; secret: string } | null {
  const header = req.headers.get("x-inspect-auth")?.trim() ?? "";
  if (header) {
    const sep = header.indexOf(":");
    if (sep > 0) {
      const linkId = header.slice(0, sep);
      const secret = header.slice(sep + 1);
      if (linkId && secret) return { linkId, secret };
    }
  }

  // Legacy: Bearer linkId:secret (may be rejected by JWT gateway — prefer x-inspect-auth)
  const auth = req.headers.get("authorization") ?? "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1]!;
  // Ignore real JWTs (service_role) — they contain dots.
  if (token.includes(".")) return null;
  const sep = token.indexOf(":");
  if (sep <= 0) return null;
  const linkId = token.slice(0, sep);
  const secret = token.slice(sep + 1);
  if (!linkId || !secret) return null;
  return { linkId, secret };
}

function clampInt(raw: string | null, fallback: number, min: number, max: number): number {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(Math.max(Math.trunc(n), min), max);
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: inspectCorsHeaders });
  }

  const route = extractRoute(req);

  try {
    if (req.method === "GET" && (route === "" || route === "health")) {
      return json({ ok: true, service: FEATURE });
    }

    const ip = clientIp(req);

    if (req.method === "POST" && route === "session") {
      let body: { link_id?: string; secret?: string };
      try {
        body = await req.json();
      } catch {
        return json({ error: { code: "invalid_json" } }, 400);
      }

      const linkId = body.link_id?.trim() ?? "";
      const secret = body.secret?.trim() ?? "";
      if (!linkId || !secret || !isUuid(linkId)) {
        return notFound();
      }

      if (isRateLimited(`ip:${ip}`)) {
        return json({ error: { code: "rate_limited", message: "rate_limited" } }, 429);
      }

      const admin = createAdminClient();
      const { data, error } = await admin.rpc("peek_attendance_inspection_access", {
        p_link_id: linkId,
        p_secret: secret,
      });
      if (error) {
        log("error", FEATURE, "peek failed", { extra: { error: error.message } });
        return notFound();
      }
      if (!data) {
        return notFound();
      }

      const peek = data as { expires_at?: string; valid?: boolean };
      return json({ ok: true, expires_at: peek.expires_at ?? null });
    }

    if (req.method === "GET" && route === "data") {
      const auth = parseInspectAuth(req);
      if (!auth || !isUuid(auth.linkId)) {
        return notFound();
      }

      // Rate-limit only session exchange (brute-force). Pagination on /data is trusted after cookie.
      const url = new URL(req.url);
      const punchesOffset = clampInt(url.searchParams.get("punches_offset"), 0, 0, 10_000_000);
      const punchesLimit = clampInt(url.searchParams.get("punches_limit"), 500, 1, 1000);
      const summariesOffset = clampInt(url.searchParams.get("summaries_offset"), 0, 0, 10_000_000);
      const summariesLimit = clampInt(url.searchParams.get("summaries_limit"), 200, 1, 500);

      const admin = createAdminClient();
      const userAgent = req.headers.get("user-agent") ?? null;
      const { data, error } = await admin.rpc("resolve_attendance_inspection_access", {
        p_link_id: auth.linkId,
        p_secret: auth.secret,
        p_punches_offset: punchesOffset,
        p_punches_limit: punchesLimit,
        p_summaries_offset: summariesOffset,
        p_summaries_limit: summariesLimit,
        p_client_ip: ip === "unknown" ? null : ip,
        p_user_agent: userAgent,
      });

      if (error) {
        log("error", FEATURE, "resolve failed", { extra: { error: error.message } });
        return notFound();
      }
      if (!data) {
        return notFound();
      }

      return json(data);
    }

    return notFound();
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown_error";
    log("error", FEATURE, "Unhandled error", { extra: { route, error: message } });
    captureException(err, { feature: FEATURE, extra: { route } });
    return json({ error: { code: "internal_error" } }, 500);
  }
});

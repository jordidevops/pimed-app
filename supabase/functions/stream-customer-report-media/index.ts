import { createAdminClient } from "../_shared/supabase.ts";
import { requireCustomerPortalBffAuth } from "../_shared/customer-portal/internal-auth.ts";
import { sha256Bytes, bytesToPostgresHex } from "../_shared/employee-portal/crypto.ts";
import { captureException, initObservability } from "../_shared/observability/system-error-tracker.ts";

const HEX_64_RE = /^[0-9a-f]{64}$/;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BUCKET = "customer-report-media";

function json(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "private, no-store",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
}

function clientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0]?.trim() || null;
  return req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip");
}

function manifestItem(
  manifest: unknown,
  objectKey: string,
): Record<string, unknown> | null {
  if (!Array.isArray(manifest)) return null;
  return (
    manifest.find((item) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return false;
      const row = item as Record<string, unknown>;
      return row.bucket === BUCKET && row.object_key === objectKey &&
        row.copy_status === "ok";
    }) as Record<string, unknown> | undefined
  ) ?? null;
}

Deno.serve(async (req: Request) => {
  initObservability();

  const unauthorized = await requireCustomerPortalBffAuth(req);
  if (unauthorized) return unauthorized;
  if (req.method !== "POST") return json(405, "method_not_allowed");

  let body: {
    actor_type?: "share" | "grant" | "staff";
    session_token?: string;
    report_version_id?: string;
    object_key?: string;
    request_id?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json(400, "invalid_body");
  }

  const actor = body.actor_type;
  const sessionToken = body.session_token;
  const objectKey = body.object_key;
  if (
    !actor ||
    !sessionToken ||
    !HEX_64_RE.test(sessionToken) ||
    !objectKey ||
    objectKey.includes("..") ||
    objectKey.startsWith("/")
  ) {
    return json(404, "not_found");
  }
  if (
    body.report_version_id &&
    !UUID_RE.test(body.report_version_id)
  ) {
    return json(404, "not_found");
  }

  try {
    const admin = createAdminClient() as any;
    const tokenHash = bytesToPostgresHex(await sha256Bytes(sessionToken));
    const ip = clientIp(req);
    const userAgent = req.headers.get("user-agent") ?? undefined;
    const auditRequestId = crypto.randomUUID();
    let resolved: unknown;
    let error: { message?: string } | null = null;

    if (actor === "share") {
      const result = await admin.rpc("resolve_customer_portal_share_session", {
        p_session_token_hash: tokenHash,
        p_action: "media_download",
        p_ip_address: ip,
        p_user_agent: userAgent,
        p_request_id: auditRequestId,
      });
      resolved = result.data;
      error = result.error;
    } else if (actor === "grant") {
      if (!body.report_version_id) return json(404, "not_found");
      const result = await admin.rpc("resolve_customer_portal_grant_session", {
        p_session_token_hash: tokenHash,
        p_action: "media_download",
        p_report_version_id: body.report_version_id,
        p_ip_address: ip,
        p_user_agent: userAgent,
        p_request_id: auditRequestId,
      });
      resolved = result.data;
      error = result.error;
    } else if (actor === "staff") {
      const result = await admin.rpc("exchange_customer_portal_staff_session", {
        p_token_hash: tokenHash,
        p_ip_address: ip,
        p_user_agent: userAgent,
        p_report_version_id: body.report_version_id ?? null,
        // Never consume URL handoffs from media; opaque cookie only.
        p_allow_handoff_consume: false,
      });
      resolved = result.data;
      error = result.error;
      const staffRow = resolved as Record<string, unknown> | null;
      if (staffRow?.consumed === true || staffRow?.code === "handoff_not_consumed") {
        return json(404, "not_found");
      }
    } else {
      return json(404, "not_found");
    }

    const row = resolved as Record<string, unknown> | null;
    if (error || !row || row.ok !== true) return json(404, "not_found");
    const item = manifestItem(row.media_manifest, objectKey);
    if (!item) return json(404, "not_found");

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRole) return json(500, "internal_error");
    const encodedKey = objectKey.split("/").map(encodeURIComponent).join("/");
    const storageHeaders = new Headers({
      Authorization: `Bearer ${serviceRole}`,
      apikey: serviceRole,
    });
    const range = req.headers.get("range");
    if (range) storageHeaders.set("Range", range);

    const storageResponse = await fetch(
      `${supabaseUrl.replace(/\/$/, "")}/storage/v1/object/${BUCKET}/${encodedKey}`,
      { method: "GET", headers: storageHeaders },
    );
    if (!storageResponse.ok || !storageResponse.body) {
      return json(storageResponse.status === 416 ? 416 : 404, "not_found");
    }

    const headers = new Headers({
      "Content-Type": String(
        item.content_type ?? storageResponse.headers.get("content-type") ??
          "application/octet-stream",
      ),
      "Cache-Control": "private, no-store",
      "Accept-Ranges": storageResponse.headers.get("accept-ranges") ?? "bytes",
      "X-Content-Type-Options": "nosniff",
    });
    for (const header of ["content-length", "content-range", "etag", "last-modified"]) {
      const value = storageResponse.headers.get(header);
      if (value) headers.set(header, value);
    }

    return new Response(storageResponse.body, {
      status: storageResponse.status,
      headers,
    });
  } catch (error) {
    captureException(error, { feature: "stream-customer-report-media" });
    return json(500, "internal_error");
  }
});

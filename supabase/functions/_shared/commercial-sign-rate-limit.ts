/**
 * CF-28 F9: commercial /sign rate limits via data.assert_customer_portal_rate_limit buckets.
 *
 * Buckets (separate budgets):
 * - commercial_sign_resolve_ip — first resolve / mark_opened
 * - commercial_sign_poll_ip — refresh resolve (mark_opened=false)
 * - commercial_sign_pdf_ip — get-document-url commercial path
 * - commercial_sign_decide_ip — accept/decline
 * - commercial_sign_token_miss — not_found / non-commercial token guesses
 */
import type { createAdminClient } from "./supabase.ts";

type AdminClient = ReturnType<typeof createAdminClient>;

export type RateLimitFail =
  | { ok: true }
  | { ok: false; code: "rate_limited" | "invalid" };

export function getClientIp(req: Request): string {
  return (
    req.headers.get("CF-Connecting-IP") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

/**
 * Enforce rate limit. On infrastructure/RPC errors: fail-open (allow) so a
 * missing migration cannot take down /sign with fake 429s.
 */
export async function checkCommercialSignRateLimit(
  admin: AdminClient,
  bucketType: string,
  clientKey: string,
  maxAttempts: number,
  windowMinutes = 1,
): Promise<RateLimitFail> {
  const { data, error } = await admin.rpc("check_commercial_sign_rate_limit", {
    p_bucket_type: bucketType,
    p_client_key: clientKey,
    p_max_attempts: maxAttempts,
    p_window_minutes: windowMinutes,
  });
  if (error) {
    console.warn(
      JSON.stringify({
        level: "warn",
        feature: "commercial-sign-rate-limit",
        msg: "rate_limit_check_failed_fail_open",
        error: error.message,
        bucketType,
      }),
    );
    return { ok: true };
  }
  const row = data as { ok?: boolean; code?: string } | null;
  if (row?.ok === true) return { ok: true };
  if (row?.code === "rate_limited") {
    await admin
      .rpc("record_commercial_ops_metric", {
        p_metric: "rate_limited",
        p_tenant_id: null,
        p_request_id: null,
        p_detail: { bucket_type: bucketType },
      })
      .catch(() => {});
    return { ok: false, code: "rate_limited" };
  }
  // invalid args → fail-open
  return { ok: true };
}

/** SHA-256 hex prefix of token for miss-bucket (never log raw token). */
export async function tokenMissKey(token: string): Promise<string> {
  const bytes = new TextEncoder().encode(token.trim());
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 32);
}

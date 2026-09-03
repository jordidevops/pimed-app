import { createAdminClient } from "../supabase.ts";

const DEFAULT_MAX_ATTEMPTS = 20;
const DEFAULT_WINDOW_MINUTES = 15;

export function extractStationClientKey(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return `ip:${first}`;
  }

  const realIp = req.headers.get("x-real-ip")?.trim();
  if (realIp) return `ip:${realIp}`;

  const cfIp = req.headers.get("cf-connecting-ip")?.trim();
  if (cfIp) return `ip:${cfIp}`;

  return "ip:unknown";
}

export function parseRateLimitRetryAfter(
  error: { message?: string; details?: string },
  defaultSeconds: number,
): number {
  const detail = error.details;
  if (detail) {
    try {
      const parsed = JSON.parse(detail) as { retry_after_seconds?: number };
      if (typeof parsed.retry_after_seconds === "number") {
        return parsed.retry_after_seconds;
      }
    } catch {
      // ignore malformed detail
    }
  }
  return defaultSeconds;
}

export interface RateLimitBlockDetail {
  bucket_type?: string;
  client_key?: string;
  tenant_id?: string;
  employee_id?: string;
  attempts?: number;
  max_attempts?: number;
  window_minutes?: number;
}

export function parseRateLimitBlockDetail(
  error: { details?: string },
): RateLimitBlockDetail | null {
  if (!error.details) return null;
  try {
    return JSON.parse(error.details) as RateLimitBlockDetail;
  } catch {
    return null;
  }
}

export async function recordStationRateLimitBlock(
  detail: RateLimitBlockDetail,
): Promise<void> {
  if (!detail.bucket_type || !detail.client_key) return;

  const db = createAdminClient();
  const { error } = await db.rpc("record_station_rate_limit_block" as never, {
    p_bucket_type: detail.bucket_type,
    p_client_key: detail.client_key,
    p_attempt_count: detail.attempts ?? 1,
    p_max_attempts: detail.max_attempts ?? 20,
    p_window_minutes: detail.window_minutes ?? 15,
    p_tenant_id: detail.tenant_id ?? null,
    p_employee_id: detail.employee_id ?? null,
  } as never);

  if (error) {
    console.warn("record_station_rate_limit_block failed:", error.message);
  }
}

export class StationRegisterRateLimitError extends Error {
  retryAfterSeconds: number;
  detail: RateLimitBlockDetail | null;

  constructor(retryAfterSeconds: number, detail: RateLimitBlockDetail | null = null) {
    super("station_register_rate_limited");
    this.name = "StationRegisterRateLimitError";
    this.retryAfterSeconds = retryAfterSeconds;
    this.detail = detail;
  }
}

export async function assertStationRegisterRateLimit(clientKey: string): Promise<void> {
  const db = createAdminClient();
  const { error } = await db.rpc("assert_station_register_rate_limit" as never, {
    p_client_key: clientKey,
    p_max_attempts: DEFAULT_MAX_ATTEMPTS,
    p_window_minutes: DEFAULT_WINDOW_MINUTES,
  } as never);

  if (!error) return;

  if (error.message.includes("station_register_rate_limited")) {
    throw new StationRegisterRateLimitError(
      parseRateLimitRetryAfter(error, DEFAULT_WINDOW_MINUTES * 60),
      parseRateLimitBlockDetail(error),
    );
  }

  throw new Error(error.message);
}

export class StationIdentityResolveRateLimitError extends Error {
  retryAfterSeconds: number;
  detail: RateLimitBlockDetail | null;

  constructor(retryAfterSeconds: number, detail: RateLimitBlockDetail | null = null) {
    super("station_identity_resolve_rate_limited");
    this.name = "StationIdentityResolveRateLimitError";
    this.retryAfterSeconds = retryAfterSeconds;
    this.detail = detail;
  }
}

export async function assertStationIdentityResolveRateLimit(clientKey: string): Promise<void> {
  const db = createAdminClient();
  const { error } = await db.rpc("assert_station_identity_resolve_rate_limit" as never, {
    p_client_key: clientKey,
    p_max_attempts: 30,
    p_window_minutes: DEFAULT_WINDOW_MINUTES,
  } as never);

  if (!error) return;

  if (
    error.message.includes("station_identity_resolve_rate_limited")
    || error.message.includes("station_register_rate_limited")
  ) {
    throw new StationIdentityResolveRateLimitError(
      parseRateLimitRetryAfter(error, DEFAULT_WINDOW_MINUTES * 60),
      parseRateLimitBlockDetail(error),
    );
  }

  throw new Error(error.message);
}

export class StationDocumentResolveRateLimitError extends Error {
  retryAfterSeconds: number;
  detail: RateLimitBlockDetail | null;

  constructor(retryAfterSeconds: number, detail: RateLimitBlockDetail | null = null) {
    super("station_document_resolve_rate_limited");
    this.name = "StationDocumentResolveRateLimitError";
    this.retryAfterSeconds = retryAfterSeconds;
    this.detail = detail;
  }
}

export async function assertStationDocumentResolveRateLimit(clientKey: string): Promise<void> {
  const db = createAdminClient();
  const { error } = await db.rpc("assert_station_document_resolve_rate_limit" as never, {
    p_client_key: clientKey,
    p_max_attempts: 20,
    p_window_minutes: DEFAULT_WINDOW_MINUTES,
  } as never);

  if (!error) return;

  if (error.message.includes("station_document_resolve_rate_limited")) {
    throw new StationDocumentResolveRateLimitError(
      parseRateLimitRetryAfter(error, DEFAULT_WINDOW_MINUTES * 60),
      parseRateLimitBlockDetail(error),
    );
  }

  throw new Error(error.message);
}

export class StationIdentityIssueRateLimitError extends Error {
  retryAfterSeconds: number;
  detail: RateLimitBlockDetail | null;

  constructor(retryAfterSeconds: number, detail: RateLimitBlockDetail | null = null) {
    super("station_identity_issue_rate_limited");
    this.name = "StationIdentityIssueRateLimitError";
    this.retryAfterSeconds = retryAfterSeconds;
    this.detail = detail;
  }
}

export function throwIfIdentityIssueRateLimited(error: { message?: string; details?: string }): void {
  if (!error.message.includes("station_identity_issue_rate_limited")) return;
  throw new StationIdentityIssueRateLimitError(
    parseRateLimitRetryAfter(error, DEFAULT_WINDOW_MINUTES * 60),
    parseRateLimitBlockDetail(error),
  );
}

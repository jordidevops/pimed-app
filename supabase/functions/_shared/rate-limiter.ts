// =============================================================================
// RateLimiter — Mòdul de rate limiting per al Worker d'email
// =============================================================================
//
// Estratègia de cascada:
//   1. Si rate_limiting_enabled = false → allowed directament
//   2. Si engine = 'redis' → Upstash REST API (primari)
//   3. Si Redis falla + fallback_to_postgres = true → RPC Postgres (pla B)
//   4. Si tot falla → fail-open (allowed = true) per no bloquejar correus
//
// La config de system_settings es cacheja en memòria (fora del handler)
// per evitar una lectura per cada invocació del Worker.
// =============================================================================

import { createAdminClient } from "./supabase.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "rate-limiter";

// ============================================================================
// Types
// ============================================================================

interface RateLimitConfig {
  rate_limiting_enabled: boolean;
  rate_limit_engine: "redis" | "postgres";
  fallback_to_postgres: boolean;
}

export interface RateLimitResult {
  allowed: boolean;
  engine: "redis" | "postgres" | "none";
}

// ============================================================================
// In-memory cache per system_settings (viu fora del handler)
// ============================================================================

const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minuts

let cachedConfig: RateLimitConfig | null = null;
let cachedAt = 0;

async function getConfig(): Promise<RateLimitConfig> {
  const now = Date.now();
  if (cachedConfig && now - cachedAt < CACHE_TTL_MS) {
    return cachedConfig;
  }

  const admin = createAdminClient();
  const { data, error } = await admin
    .from("system_settings")
    .select("settings")
    .eq("module", "rate_limiting")
    .single();

  if (error || !data) {
    log("error", FEATURE, "Error loading rate limit config", {
      extra: { error: error?.message },
    });
    // Default segur: postgres, fallback actiu
    return {
      rate_limiting_enabled: true,
      rate_limit_engine: "postgres",
      fallback_to_postgres: true,
    };
  }

  cachedConfig = data.settings as RateLimitConfig;
  cachedAt = now;
  return cachedConfig;
}

// ============================================================================
// Redis (Upstash REST API) — Motor primari
// ============================================================================

const UPSTASH_URL = Deno.env.get("UPSTASH_REDIS_REST_URL") ?? "";
const UPSTASH_TOKEN = Deno.env.get("UPSTASH_REDIS_REST_TOKEN") ?? "";

async function checkRedis(
  tenantId: string,
  maxHour: number,
  maxDay: number,
): Promise<boolean> {
  const now = new Date();
  const hourKey = `rl:${tenantId}:h:${now.toISOString().slice(0, 13)}`;
  const dayKey = `rl:${tenantId}:d:${now.toISOString().slice(0, 10)}`;

  // Pipeline atòmic: INCR + EXPIRE per ambdues finestres
  const pipeline = [
    ["INCR", hourKey],
    ["EXPIRE", hourKey, "3600"],
    ["INCR", dayKey],
    ["EXPIRE", dayKey, "86400"],
  ];

  const res = await fetch(`${UPSTASH_URL}/pipeline`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${UPSTASH_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(pipeline),
  });

  if (!res.ok) {
    throw new Error(`Upstash HTTP ${res.status}: ${await res.text()}`);
  }

  const results = (await res.json()) as { result: number }[];
  const hourCount = results[0].result;
  const dayCount = results[2].result;

  return (
    (maxHour <= 0 || hourCount <= maxHour) &&
    (maxDay <= 0 || dayCount <= maxDay)
  );
}

// ============================================================================
// Postgres Fallback (Pla B)
// ============================================================================

async function checkPostgres(
  tenantId: string,
  maxHour: number,
  maxDay: number,
): Promise<boolean> {
  const admin = createAdminClient();
  const { data, error } = await admin.rpc("check_and_increment_worker_limit", {
    p_tenant_id: tenantId,
    p_max_hour: maxHour,
    p_max_day: maxDay,
  });

  if (error) {
    throw new Error(`Postgres RPC error: ${error.message}`);
  }

  return data as boolean;
}

// ============================================================================
// API Pública
// ============================================================================

/**
 * Comprova si un tenant pot enviar un correu dins dels seus límits.
 *
 * Ús al Worker:
 * ```ts
 * import { checkRateLimit } from "../_shared/rate-limiter.ts";
 *
 * const { allowed, engine } = await checkRateLimit(tenantId, maxHour, maxDay);
 * if (!allowed) {
 *   // Aplicar VT llarg a pgmq perquè reaparegui a la finestra següent
 * }
 * ```
 */
export async function checkRateLimit(
  tenantId: string,
  maxHour: number,
  maxDay: number,
): Promise<RateLimitResult> {
  const config = await getConfig();

  // Rate limiting desactivat → sempre permès
  if (!config.rate_limiting_enabled) {
    return { allowed: true, engine: "none" };
  }

  // === Motor: Redis (primari) ===
  if (config.rate_limit_engine === "redis") {
    try {
      const allowed = await checkRedis(tenantId, maxHour, maxDay);
      return { allowed, engine: "redis" };
    } catch (err) {
      log("warn", FEATURE, "Redis failed, trying Postgres fallback", {
        tenantId,
        extra: { error: (err as Error).message },
      });

      if (config.fallback_to_postgres) {
        try {
          const allowed = await checkPostgres(tenantId, maxHour, maxDay);
          return { allowed, engine: "postgres" };
        } catch (pgErr) {
          log("error", FEATURE, "Postgres fallback also failed", {
            tenantId,
            extra: { error: (pgErr as Error).message },
          });
          // Ambdós han fallat → fail-open per no bloquejar correus
          return { allowed: true, engine: "none" };
        }
      }

      // Sense fallback configurat → fail-open
      return { allowed: true, engine: "none" };
    }
  }

  // === Motor: Postgres (directe) ===
  try {
    const allowed = await checkPostgres(tenantId, maxHour, maxDay);
    return { allowed, engine: "postgres" };
  } catch (err) {
    log("error", FEATURE, "Postgres rate limit check failed", {
      tenantId,
      extra: { error: (err as Error).message },
    });
    // fail-open
    return { allowed: true, engine: "none" };
  }
}

/**
 * Invalida la cache de config (útil si l'admin canvia settings en calent).
 */
export function invalidateConfigCache(): void {
  cachedConfig = null;
  cachedAt = 0;
}

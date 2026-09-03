/**
 * Rate limiter del Route Handler de leads.
 *
 * Estratègia:
 *   1) Si UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN existeixen,
 *      usa límit distribuït (@upstash/ratelimit) per suportar multi-instància.
 *   2) Si no hi ha config, o Upstash falla temporalment, fallback a memòria local.
 */

import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";

interface WindowEntry {
  count: number;
  /** Timestamp (ms) de quan expira la finestra */
  expiresAt: number;
}

interface DistributedLimiter {
  limit: (key: string) => Promise<{ success: boolean }>;
}

// Estat global de la instància
const windows = new Map<string, WindowEntry>();
const MAX_WINDOW_KEYS = 10_000;

let upstashRedis: Redis | null = null;
let upstashBootstrapped = false;
const distributedLimiters = new Map<string, DistributedLimiter>();

// Neteja periòdica per evitar fuita de memòria (elimina entrades expirades)
// S'executa cada ~1 min en invocar checkRateLimit si el Map té entrades
let lastCleanup = Date.now();
function maybeCleanup(): void {
  const now = Date.now();
  if (now - lastCleanup < 60_000) return;
  lastCleanup = now;
  for (const [key, entry] of windows.entries()) {
    if (entry.expiresAt < now) windows.delete(key);
  }
}

function getDistributedLimiter(limit: number, windowMs: number): DistributedLimiter | null {
  if (!upstashBootstrapped) {
    upstashBootstrapped = true;
    const url = process.env.UPSTASH_REDIS_REST_URL;
    const token = process.env.UPSTASH_REDIS_REST_TOKEN;
    if (url && token) {
      upstashRedis = new Redis({ url, token });
    }
  }

  if (!upstashRedis) return null;

  const seconds = Math.max(1, Math.floor(windowMs / 1000));
  const cacheKey = `${limit}:${seconds}`;
  const cached = distributedLimiters.get(cacheKey);
  if (cached) return cached;

  const limiter = new Ratelimit({
    redis: upstashRedis,
    limiter: Ratelimit.slidingWindow(limit, `${seconds} s`),
    analytics: false,
    prefix: "leads:rl",
  });

  const wrapped: DistributedLimiter = {
    limit: (key: string) => limiter.limit(key),
  };
  distributedLimiters.set(cacheKey, wrapped);
  return wrapped;
}

function checkRateLimitLocal(
  key: string,
  limit: number,
  windowMs = 60_000,
): boolean {
  maybeCleanup();

  // Protecció bàsica contra creixement il·limitat sota atac distribuït.
  if (windows.size >= MAX_WINDOW_KEYS) {
    maybeCleanup();
    if (windows.size >= MAX_WINDOW_KEYS) {
      const overflow = windows.size - MAX_WINDOW_KEYS + 1;
      let removed = 0;
      for (const oldestKey of windows.keys()) {
        windows.delete(oldestKey);
        removed += 1;
        if (removed >= overflow) break;
      }
    }
  }

  const now = Date.now();
  const existing = windows.get(key);

  if (!existing || existing.expiresAt < now) {
    // Nova finestra
    windows.set(key, { count: 1, expiresAt: now + windowMs });
    return true;
  }

  existing.count += 1;

  if (existing.count > limit) {
    return false; // superat el límit
  }

  return true;
}

/**
 * Comprova si una clau (ex: IP, o IP:host) ha superat el límit.
 *
 * @param key       - identificador (ex: remoteIp o `${ip}:${host}`)
 * @param limit     - nombre màxim de peticions permeses per finestra
 * @param windowMs  - durada de la finestra en mil·lisegons (default: 60s)
 * @returns true si DINS del límit (petició permesa), false si superat
 */
export async function checkRateLimit(
  key: string,
  limit: number,
  windowMs = 60_000,
): Promise<boolean> {
  const distributed = getDistributedLimiter(limit, windowMs);
  if (!distributed) {
    return checkRateLimitLocal(key, limit, windowMs);
  }

  try {
    const result = await distributed.limit(key);
    return result.success;
  } catch (err) {
    console.warn("[rate-limit] Upstash unavailable, fallback to local limiter:", err);
    return checkRateLimitLocal(key, limit, windowMs);
  }
}

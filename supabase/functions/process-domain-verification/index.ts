/**
 * process-domain-verification
 *
 * Worker per a la verificació periòdica de dominis propis dels portals públics.
 * Cridat per pg_cron cada 5 minuts via data.invoke_domain_verification_worker().
 *
 * Flux per domini:
 *   pending      → comprova DNS TXT (<prefix>.<domain> = verification_token)
 *                  → èxit: dns_verified (check_count=0) | fallada: increment check_count
 *                  → si check_count >= MAX_CHECK_ATTEMPTS: failed
 *   dns_verified → comprova SSL (HTTPS HEAD al domini)
 *                  → èxit: ssl_active (check_count=0) | fallada: increment check_count
 *                  → si check_count >= MAX_CHECK_ATTEMPTS: failed
 *   failed       → reintentat cada 1h: comprova DNS TXT
 *                  → èxit: dns_verified (check_count=0) | fallada: actualitza last_checked_at
 *                  → NO incrementa check_count (ja és failed; evita loop de reset)
 *
 * DNS Check: Cloudflare DNS-over-HTTPS per a consultes TXT sense dependències.
 * SSL Check: HTTPS HEAD al domini (timeout 10s).
 *
 * Auditing: cada transició d'estat escriu a data.public_domain_events
 * via trigger trg_audit_public_domains (20260513000001_public_portal_core.sql).
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-domain-verification \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
 *     -H "Content-Type: application/json" \
 *     -d '{"batch_size": 5}'
 */

import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log, timedCall, defaultSlowHandler } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "process-domain-verification";
const EXTERNAL_CHECK_SLOW_MS = 10_000;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BATCH_SIZE_DEFAULT = 20;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

/** Prefix del registre TXT per a verificació de domini (sense el sufix del domini) */
const DNS_TXT_PREFIX =
  (Deno.env.get("PORTAL_DNS_TXT_PREFIX") || "_portal-verify")
    .trim()
    .replace(/\.$/, "");

/** URL de Cloudflare DNS-over-HTTPS (anònim, no té cookies ni autenticació) */
const DOH_URL = "https://cloudflare-dns.com/dns-query";

/** Timeout per al check DNS (ms) */
const DNS_TIMEOUT_MS = 8000;

/** Timeout per al check SSL (ms) */
const SSL_TIMEOUT_MS = 10000;

/**
 * Nombre màxim d'intents fallits consecutius abans de transicionar a 'failed'.
 * 100 checks × 5 min cron = ~8.3h. Raonable per a DNS i SSL V1.
 * Rang: pending→dns_verified i dns_verified→ssl_active ambdós usen el mateix llindar.
 */
const MAX_CHECK_ATTEMPTS = 100;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface DomainRow {
  id: string;
  public_site_id: string;
  tenant_id: string;
  domain: string;
  status: "pending" | "dns_verified" | "ssl_active" | "failed";
  verification_token: string;
  check_count: number;
  last_checked_at: string | null;
  failure_reason: string | null;
}

interface DomainCheckResult {
  domain_id: string;
  domain: string;
  old_status: string;
  new_status: string;
  success: boolean;
  error?: string;
}

interface BatchSummary {
  total: number;
  dns_verified: number;
  ssl_active: number;
  unchanged: number;
  failed: number;
  errors: string[];
}

// ---------------------------------------------------------------------------
// DNS-over-HTTPS check
// ---------------------------------------------------------------------------

/**
 * Comprova si el registre TXT `<prefix>.<domain>` conté el token esperat.
 * Usa Cloudflare DoH (application/dns-json) per a consultes sense dependències.
 * Retorna true si el token és present entre els valors TXT, false otherwise.
 */
async function checkDnsTxt(
  domain: string,
  expectedToken: string
): Promise<boolean> {
  const verifySubdomain = `${DNS_TXT_PREFIX}.${domain}`;
  const url = `${DOH_URL}?name=${encodeURIComponent(verifySubdomain)}&type=TXT`;

  return timedCall(
    FEATURE,
    "cloudflare_doh",
    EXTERNAL_CHECK_SLOW_MS,
    async () => {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), DNS_TIMEOUT_MS);

      const response = await fetch(url, {
        headers: { Accept: "application/dns-json" },
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      if (!response.ok) return false;

      const data = await response.json() as {
        Status: number;
        Answer?: Array<{ type: number; data: string }>;
      };

      if (data.Status !== 0 || !data.Answer) return false;

      return data.Answer.some(
        (record) =>
          record.type === 16 &&
          record.data.replace(/^"|"$/g, "").trim() === expectedToken.trim()
      );
    },
    defaultSlowHandler(FEATURE, "cloudflare_doh", EXTERNAL_CHECK_SLOW_MS),
  ).catch(() => false);
}

// ---------------------------------------------------------------------------
// SSL check
// ---------------------------------------------------------------------------

/**
 * Comprova si el domini respon per HTTPS.
 * Usa un HEAD request (mínim tràfic) amb seguiment de redireccions.
 * Considera SSL actiu si la resposta és qualsevol codi HTTP (fins i tot 4xx/5xx),
 * perquè el que volem confirmar és que hi ha certificat TLS vàlid.
 */
async function checkSsl(domain: string): Promise<boolean> {
  return timedCall(
    FEATURE,
    "ssl_head_check",
    EXTERNAL_CHECK_SLOW_MS,
    async () => {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), SSL_TIMEOUT_MS);

      const response = await fetch(`https://${domain}`, {
        method: "HEAD",
        redirect: "follow",
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      return response.status > 0;
    },
    defaultSlowHandler(FEATURE, "ssl_head_check", EXTERNAL_CHECK_SLOW_MS),
  ).catch(() => false);
}

// ---------------------------------------------------------------------------
// Domain processing helpers
// ---------------------------------------------------------------------------

/**
 * Actualitza camps d'un domini via l'RPC api.update_domain_check_result.
 * Usa JSONB patch: només els camps presents al diccionari es modifiquen.
 * last_checked_at s'actualitza sempre a now() dins la funció SQL.
 */
async function updateDomain(
  db: ReturnType<typeof createAdminClient>,
  id: string,
  fields: Record<string, string | number | null>
): Promise<void> {
  const { error } = await db.rpc("update_domain_check_result", {
    p_id: id,
    p_updates: fields,
  });
  if (error) throw new Error(`DB update: ${error.message}`);
}

// ---------------------------------------------------------------------------
// Domain processing
// ---------------------------------------------------------------------------

async function processDomain(
  db: ReturnType<typeof createAdminClient>,
  row: DomainRow
): Promise<DomainCheckResult> {
  const result: DomainCheckResult = {
    domain_id: row.id,
    domain: row.domain,
    old_status: row.status,
    new_status: row.status,
    success: true,
  };

  try {
    if (row.status === "pending" || row.status === "failed") {
      // Pas 1: verificació DNS TXT
      const dnsOk = await checkDnsTxt(row.domain, row.verification_token);

      if (dnsOk) {
        // Transició: pending/failed → dns_verified. Reset check_count per SSL fresh start.
        await updateDomain(db, row.id, {
          status: "dns_verified",
          check_count: 0,
          failure_reason: null,
        });
        result.new_status = "dns_verified";
      } else if (row.status === "failed") {
        // Domini ja en 'failed': reintentem sense incrementar check_count.
        // Només actualitzem last_checked_at (la funció SQL ho fa sempre) + failure_reason.
        await updateDomain(db, row.id, {
          failure_reason: "DNS TXT record not found or token mismatch",
        });
        result.new_status = "failed"; // sense canvi d'estat
      } else {
        // Status 'pending': incrementa check_count → si >= limit, transiciona a failed.
        const newCheckCount = row.check_count + 1;
        if (newCheckCount >= MAX_CHECK_ATTEMPTS) {
          await updateDomain(db, row.id, {
            status: "failed",
            check_count: newCheckCount,
            failure_reason: `DNS TXT no configurat despres de ${newCheckCount} intents (~${Math.round(newCheckCount * 5 / 60)}h)`,
          });
          result.new_status = "failed";
        } else {
          await updateDomain(db, row.id, {
            check_count: newCheckCount,
            failure_reason: "DNS TXT record not found or token mismatch",
          });
          result.new_status = "pending"; // sense canvi d'estat
        }
      }
    } else if (row.status === "dns_verified") {
      // Pas 2: verificació SSL (després del DNS)
      const sslOk = await checkSsl(row.domain);

      if (sslOk) {
        // Transició: dns_verified → ssl_active. Reset check_count.
        await updateDomain(db, row.id, {
          status: "ssl_active",
          check_count: 0,
          ssl_provisioned_at: new Date().toISOString(),
          failure_reason: null,
        });
        result.new_status = "ssl_active";
      } else {
        // SSL encara pendent: incrementa check_count → si >= limit, transiciona a failed.
        const newCheckCount = row.check_count + 1;
        if (newCheckCount >= MAX_CHECK_ATTEMPTS) {
          await updateDomain(db, row.id, {
            status: "failed",
            check_count: newCheckCount,
            failure_reason: `SSL no actiu despres de ${newCheckCount} intents (~${Math.round(newCheckCount * 5 / 60)}h)`,
          });
          result.new_status = "failed";
        } else {
          await updateDomain(db, row.id, {
            check_count: newCheckCount,
            failure_reason: "SSL certificate not yet active (provisioning may take up to 48h)",
          });
          result.new_status = "dns_verified"; // sense canvi d'estat
        }
      }
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    result.success = false;
    result.error = errMsg;
    result.new_status = row.status;

    // Escriu l'error sense trencar el flux del batch (best-effort)
    try {
      await updateDomain(db, row.id, {
        failure_reason: `Worker error: ${errMsg.slice(0, 255)}`,
      });
    } catch {
      // Ignora errors d'escriptura de l'error (no bloquejar el batch)
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${SERVICE_ROLE_KEY}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let batchSize = BATCH_SIZE_DEFAULT;
  try {
    const body = await req.json().catch(() => ({}));
    if (typeof body.batch_size === "number" && body.batch_size > 0) {
      batchSize = Math.min(body.batch_size, 50); // cap a 50
    }
  } catch {
    // body no parsejable → usa default
  }

  const db = createAdminClient();
  const operationLog = createOperationLogService(db);
  const summary: BatchSummary = {
    total: 0,
    dns_verified: 0,
    ssl_active: 0,
    unchanged: 0,
    failed: 0,
    errors: [],
  };

  try {
    // Llegeix dominis pendents via RPC api.fetch_domains_for_verification (SECURITY DEFINER).
    // No s'usa .schema("data") directament: data.* no ha d'estar exposat a PostgREST.
    const { data: domains, error: fetchErr } = await db.rpc(
      "fetch_domains_for_verification",
      { p_batch_size: batchSize }
    );

    if (fetchErr) {
      throw new Error(`Fetch domains: ${fetchErr.message}`);
    }

    const pendingDomains = (domains ?? []) as DomainRow[];
    summary.total = pendingDomains.length;

    // Processa dominis seqüencialment (DNS/SSL checks externs → no cal paral·lelisme)
    for (const domain of pendingDomains) {
      const result = await processDomain(db, domain);

      if (!result.success) {
        summary.failed++;
        summary.errors.push(`${domain.domain}: ${result.error}`);
        await operationLog.log({
          tenantId: domain.tenant_id,
          integrationType: "other",
          operationCode: "domain_verification",
          status: "failed",
          title: "Error verificant domini del portal",
          message: (result.error ?? "unknown").slice(0, 200),
          errorCode: "verification_worker_error",
          correlationId: domain.id,
          entityType: "public_domain",
          entityId: domain.id,
          externalService: "dns_ssl",
          isRetryable: true,
          payloadSummary: { domain: domain.domain },
        }).catch(() => undefined);
      } else if (result.new_status === "failed" && result.old_status !== "failed") {
        summary.failed++;
        await operationLog.log({
          tenantId: domain.tenant_id,
          integrationType: "other",
          operationCode: "domain_verification",
          status: "failed",
          title: "Verificació de domini fallida",
          message: `Domini ${domain.domain} no ha passat la verificació`,
          errorCode: "verification_failed",
          correlationId: domain.id,
          entityType: "public_domain",
          entityId: domain.id,
          externalService: "dns_ssl",
          isRetryable: false,
          payloadSummary: { domain: domain.domain, old_status: result.old_status },
        }).catch(() => undefined);
      } else if (result.new_status === "ssl_active") {
        summary.ssl_active++;
      } else if (result.new_status === "dns_verified" && result.old_status !== "dns_verified") {
        summary.dns_verified++;
      } else {
        summary.unchanged++;
      }
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Fatal batch error", { extra: { error: errMsg } });
    captureException(err, { feature: FEATURE });
    return new Response(
      JSON.stringify({ error: errMsg, summary }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  log("info", FEATURE, "Batch complete", { extra: summary as unknown as Record<string, unknown> });

  return new Response(JSON.stringify(summary), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

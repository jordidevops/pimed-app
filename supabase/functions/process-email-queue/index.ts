/**
 * process-email-queue — Refactored with QueueRunner
 *
 * Processa missatges de 'email_send_queue'. Encapsula la lògica d'enviament
 * amb Resend, rate limiting, renderització de plantilles i la màquina d'estats
 * de email_logs.
 *
 * Canvis respecte la versió anterior:
 *   - Usa QueueRunner per al dedup, retry exponencial i DLQ.
 *   - defaultTask: 'send_email' perquè els missatges legacy no porten camp `task`.
 *   - El handler gestiona l'estat intern de email_logs (selfManaged).
 *   - Substituit api.pop_email_messages per api.read_queue_batch (genèric).
 *   - Elimina l'helper archiveMessage local (ara ho fa QueueRunner).
 *   - Preserva el lock Redis i el multi-batch loop.
 *
 * State machine de email_logs:
 *   queued → processing → sent        (success: true → QueueRunner arxiva)
 *   queued → processing → failed      (retryable: success:false,selfManaged:true → VT expira)
 *   queued → processing → dead_letter (terminal: success:true → QueueRunner arxiva)
 *   Rate limited                      (selfManaged:true → VT expira, no canvia l'estat del log)
 */
import { corsHeaders } from "../_shared/cors.ts";
import {
  resolveEmailAttachmentsForResend,
  type EmailAttachmentRef,
} from "../_shared/email-attachments.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { checkRateLimit } from "../_shared/rate-limiter.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
} from "../_shared/queue-runtime.ts";
import { renderLiquid } from "../_shared/liquid-renderer.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { defaultSlowHandler, log, timedCall } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { classifyEmailError, isInfrastructureBug } from "../_shared/observability/helpers.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Payload dels missatges a email_send_queue (format legacy sense camp `task`). */
interface EmailQueuePayload extends TaskPayload {
  msg_id: number;
  email_log_id: string;
  priority: number;
  scheduled_at: string | null;
}

interface EmailLog {
  id: string;
  tenant_id: string;
  site_id: string | null;
  status: string;
  from_email: string;
  from_name: string | null;
  to_emails: string[];
  cc_emails: string[] | null;
  bcc_emails: string[] | null;
  reply_to: string | null;
  template_id: string | null;
  template_variables: Record<string, unknown> | null;
  layout_id: string | null;
  subject: string;
  html_body: string | null;
  text_body: string | null;
  attachments: EmailAttachmentRef[] | null;
  attempt_count: number;
  max_retries: number;
  metadata: Record<string, unknown> | null;
}

interface SiteEmailOverrides {
  logo_url: string | null;
  tenant_name_fallback: string | null;
}

interface TenantConfig {
  rate_limit_per_hour: number;
  rate_limit_per_day: number;
  layout_variables: Record<string, string> | null;
  logo_url: string | null;
  tenant_name_fallback: string | null;
}

interface ResendSuccessResponse {
  id: string;
}

interface ResendErrorResponse {
  statusCode: number;
  message: string;
  name: string;
}

interface WorkerStats {
  total: number;
  succeeded: number;
  skipped: number;
  retried: number;
  dlqed: number;
  batches: number;
}

type TemplateTranslations = Record<string, { subject?: string; html?: string; text?: string }>;

interface EmailTemplate {
  subject_template: string;
  html_body_template: string | null;
  text_body_template: string | null;
  translations: TemplateTranslations | null;
}

interface EmailLayoutTemplate {
  html_body_template: string | null;
  translations: TemplateTranslations | null;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BATCH_SIZE = 50;
/** Safety margin: exit before the Edge Function hard limit (~50s) */
const MAX_EXECUTION_MS = 40_000;
const LOCK_KEY = "email-worker:lock";
const LOCK_TTL_S = 45;
const WORKER_ID = crypto.randomUUID();

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

const UPSTASH_URL = Deno.env.get("UPSTASH_REDIS_REST_URL") ?? "";
const UPSTASH_TOKEN = Deno.env.get("UPSTASH_REDIS_REST_TOKEN") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

// ---------------------------------------------------------------------------
// Singleton Lock (Redis SET NX / Fallback: sense lock)
// ---------------------------------------------------------------------------

async function acquireLock(): Promise<boolean> {
  if (!UPSTASH_URL) {
    // Sense Redis → acceptem execució concurrent.
    // pgmq.read() és atòmic: dos workers no processen el mateix missatge.
    log("warn", "process-email-queue", "No UPSTASH_URL configured — running without lock");
    return true;
  }

  try {
    const res = await fetch(
      `${UPSTASH_URL}/set/${LOCK_KEY}/${WORKER_ID}/EX/${LOCK_TTL_S}/NX`,
      { headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` } },
    );
    const data = await res.json();
    return data.result === "OK";
  } catch (err) {
    log("warn", "process-email-queue", "Redis lock failed, proceeding without lock", {
      extra: { error: (err as Error).message },
    });
    return true;
  }
}

async function releaseLock(): Promise<void> {
  if (!UPSTASH_URL) return;

  try {
    // Lua eval via Upstash REST: only delete if we own the lock
    const script = `if redis.call("get",KEYS[1]) == ARGV[1] then return redis.call("del",KEYS[1]) else return 0 end`;
    await fetch(`${UPSTASH_URL}/eval`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${UPSTASH_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify([script, 1, LOCK_KEY, WORKER_ID]),
    });
  } catch {
    // Best-effort release; TTL will clean up anyway
  }
}

// ---------------------------------------------------------------------------
// Per-tenant config cache (within single invocation)
// ---------------------------------------------------------------------------

const configCache = new Map<string, TenantConfig>();

async function getTenantConfig(
  adminClient: ReturnType<typeof createAdminClient>,
  tenantId: string,
): Promise<TenantConfig> {
  const cached = configCache.get(tenantId);
  if (cached) return cached;

  const { data } = await adminClient
    .from("email_configs")
    .select("rate_limit_per_hour, rate_limit_per_day, layout_variables, logo_url, tenant_name_fallback")
    .eq("tenant_id", tenantId)
    .single();

  const config: TenantConfig = {
    rate_limit_per_hour: data?.rate_limit_per_hour ?? 100,
    rate_limit_per_day: data?.rate_limit_per_day ?? 1000,
    layout_variables: (data?.layout_variables as Record<string, string> | null) ?? null,
    logo_url: (data as Record<string, unknown> | null)?.logo_url as string | null ?? null,
    tenant_name_fallback: (data as Record<string, unknown> | null)?.tenant_name_fallback as string | null ?? null,
  };
  configCache.set(tenantId, config);
  return config;
}

// ---------------------------------------------------------------------------
// Site email overrides (logo + nom de marca per site)
// ---------------------------------------------------------------------------

async function getSiteEmailOverrides(
  adminClient: ReturnType<typeof createAdminClient>,
  siteId: string,
): Promise<SiteEmailOverrides | null> {
  const { data } = await adminClient
    .from("sites")
    .select("email_logo_url, email_tenant_name_fallback")
    .eq("id", siteId)
    .single();

  if (!data) return null;
  const row = data as Record<string, unknown>;
  return {
    logo_url: (row.email_logo_url as string | null) ?? null,
    tenant_name_fallback: (row.email_tenant_name_fallback as string | null) ?? null,
  };
}

// ---------------------------------------------------------------------------
// Resend API
// ---------------------------------------------------------------------------

/** Escapes HTML special characters per a ús segur en atributs i text HTML. */
function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

async function sendViaResend(
  email: EmailLog,
  idempotencyKey: string,
  adminClient: ReturnType<typeof createAdminClient>,
): Promise<ResendSuccessResponse> {
  const trimmedFromName = email.from_name?.trim() || null
  const payload: Record<string, unknown> = {
    from: trimmedFromName
      ? `${trimmedFromName} <${email.from_email}>`
      : email.from_email,
    to: email.to_emails,
    subject: email.subject,
  };

  if (email.html_body) payload.html = email.html_body;
  if (email.text_body) payload.text = email.text_body;
  if (email.cc_emails?.length) payload.cc = email.cc_emails;
  if (email.bcc_emails?.length) payload.bcc = email.bcc_emails;
  if (email.reply_to) payload.reply_to = email.reply_to;

  const resendAttachments = await resolveEmailAttachmentsForResend(
    adminClient,
    email.tenant_id,
    email.attachments,
  );
  if (resendAttachments.length > 0) {
    payload.attachments = resendAttachments;
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
      "Idempotency-Key": idempotencyKey,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as ResendErrorResponse | null;
    throw new Error(
      `Resend ${res.status}: ${body?.message ?? await res.text()}`,
    );
  }

  return (await res.json()) as ResendSuccessResponse;
}

// ---------------------------------------------------------------------------
// Email log status helpers (direct PostgREST updates via service_role)
//
// State machine: queued → processing → sent | failed
//                failed → queued (retry, if attempt_count < max_retries)
// ---------------------------------------------------------------------------

async function markProcessing(
  adminClient: ReturnType<typeof createAdminClient>,
  emailLogId: string,
): Promise<void> {
  const { error } = await adminClient
    .from("worker_email_logs")
    .update({ status: "processing", locked_by: WORKER_ID })
    .eq("id", emailLogId);

  if (error) throw new Error(`markProcessing: ${error.message}`);
}

async function markSent(
  adminClient: ReturnType<typeof createAdminClient>,
  emailLogId: string,
  providerMessageId: string,
  renderedSubject?: string | null,
  renderedHtmlBody?: string | null,
  renderedTextBody?: string | null,
): Promise<void> {
  const { error: msgErr } = await adminClient
    .from("worker_email_logs")
    .update({
      provider_message_id: providerMessageId,
      // Persistim el contingut renderitzat perquè sigui consultable
      ...(renderedSubject !== undefined && { subject: renderedSubject }),
      ...(renderedHtmlBody !== undefined && { html_body: renderedHtmlBody }),
      ...(renderedTextBody !== undefined && { text_body: renderedTextBody }),
    })
    .eq("id", emailLogId);

  if (msgErr) throw new Error(`markSent: ${msgErr.message}`);

  const { error: webhookErr } = await adminClient.rpc(
    "process_email_webhook",
    {
      p_provider_message_id: providerMessageId,
      p_new_status: "sent",
      p_metadata: { worker_id: WORKER_ID },
    },
  );

  if (webhookErr) throw new Error(`markSent: ${webhookErr.message}`);
}

async function markFailed(
  adminClient: ReturnType<typeof createAdminClient>,
  emailLogId: string,
  errorMsg: string,
  attemptCount: number,
  maxRetries: number,
): Promise<void> {
  // 1. processing → failed (trigger validates the transition)
  const { error: failErr } = await adminClient
    .from("worker_email_logs")
    .update({
      status: "failed",
      last_error: errorMsg,
      attempt_count: attemptCount + 1,
    })
    .eq("id", emailLogId);

  if (failErr) throw new Error(`markFailed: ${failErr.message}`);

  // 2. Retry or dead-letter
  if (attemptCount + 1 < maxRetries) {
    // failed → queued (trigger validates attempt_count < max_retries)
    const { error: retryErr } = await adminClient
      .from("worker_email_logs")
      .update({ status: "queued" })
      .eq("id", emailLogId);

    if (retryErr) {
      log("warn", "process-email-queue", "Could not retry email log", {
        extra: { email_log_id: emailLogId, error: retryErr.message },
      });
    }
  } else {
    // No retries left → mark as dead letter
    await adminClient
      .from("worker_email_logs")
      .update({ is_dead_letter: true })
      .eq("id", emailLogId);
  }
}

// ---------------------------------------------------------------------------
// TaskHandler: send_email
//
// Tota la lògica de processament es troba aquí. El QueueRunner gestiona
// el dedup, el retry exponencial i el DLQ de forma genèrica.
// El handler retorna TaskResult indicant si l'estat és terminal o transient.
// ---------------------------------------------------------------------------

const sendEmailHandler: TaskHandler = async (rawPayload, ctx): Promise<{ success: boolean; selfManaged?: boolean }> => {
  const msg = rawPayload as EmailQueuePayload;
  const adminClient = ctx.db;
  const operationLog = createOperationLogService(adminClient);
  const feature = "process-email-queue";
  const sendStarted = Date.now();

  // 1. Rate limit check
  const config = await getTenantConfig(adminClient, msg.tenant_id);
  const { allowed } = await checkRateLimit(
    msg.tenant_id,
    config.rate_limit_per_hour,
    config.rate_limit_per_day,
  );

  if (!allowed) {
    // Rate limited: no canviem l'estat del log. Deixem que el VT expiri.
    return { success: false, selfManaged: true };
  }

  // 2. Fetch full email log
  const { data: emailLog, error: fetchErr } = await adminClient
    .from("worker_email_logs")
    .select("*")
    .eq("id", msg.email_log_id)
    .single();

  if (fetchErr || !emailLog) {
    log("error", "process-email-queue", "email_log not found", {
      tenantId: msg.tenant_id,
      correlationId: msg.email_log_id,
      extra: { error: fetchErr?.message },
    });
    // Log no existeix → arxivem (estat terminal: no cal retry)
    return { success: true };
  }

  const typedLog = emailLog as EmailLog;

  // 3. Guard: only process emails that are still queued
  if (typedLog.status !== "queued") {
    // Ja processat (duplicat, mogut manualment) → arxivem i saltem
    return { success: true };
  }

  // 4. Mark as processing (queued → processing)
  await markProcessing(adminClient, msg.email_log_id);

  const locale = (typedLog.metadata?.locale as string | undefined) ?? "ca";

  try {
    // 5a. Renderitzar plantilla si aplica
    if (typedLog.template_id) {
      const { data: template, error: tplErr } = await adminClient
        .from("email_templates")
        .select("subject_template, html_body_template, text_body_template, translations")
        .eq("id", typedLog.template_id)
        .single();

      if (tplErr || !template) {
        throw new Error(`Template ${typedLog.template_id} not found: ${tplErr?.message}`);
      }

      const rawVars = (typedLog.template_variables ?? {}) as Record<string, unknown>;
      const variables = Object.fromEntries(
        Object.entries(rawVars).map(([key, value]) => [key, String(value ?? "")]),
      ) as Record<string, string>;

      const tpl = template as EmailTemplate;
      const localeData = (locale !== "ca" && tpl.translations)
        ? (tpl.translations[locale] ?? null)
        : null;

      const resolvedSubject = localeData?.subject ?? tpl.subject_template;
      const resolvedHtml    = localeData?.html    ?? tpl.html_body_template;
      const resolvedText    = localeData?.text    ?? tpl.text_body_template;

      // Construir context Liquid: variables al root + globals
      const emailNow  = new Date();
      const emailToday = emailNow.toISOString().split("T")[0];
      const liquidCtx: Record<string, unknown> = {
        ...(variables as Record<string, unknown>),
        globals: {
          today: emailToday,
          date:  emailToday,
          year:  String(emailNow.getFullYear()),
          now:   emailNow.toISOString(),
        },
      };

      typedLog.subject   = await renderLiquid(resolvedSubject, liquidCtx);
      typedLog.html_body = resolvedHtml ? await renderLiquid(resolvedHtml, liquidCtx) : null;
      typedLog.text_body = resolvedText ? await renderLiquid(resolvedText, liquidCtx) : null;
    }

    // 5b. Renderitzar layout si aplica
    if (typedLog.layout_id && typedLog.html_body) {
      const { data: layoutTemplate, error: layoutErr } = await adminClient
        .from("email_templates")
        .select("html_body_template, translations")
        .eq("id", typedLog.layout_id)
        .single();

      if (layoutErr || !layoutTemplate) {
        throw new Error(`Layout ${typedLog.layout_id} not found: ${layoutErr?.message}`);
      }

      const layout = layoutTemplate as EmailLayoutTemplate;
      const layoutLocaleData = (locale !== "ca" && layout.translations)
        ? (layout.translations[locale] ?? null)
        : null;
      const resolvedLayoutHtml = layoutLocaleData?.html ?? layout.html_body_template;

      if (resolvedLayoutHtml) {
        const tenantConfig = await getTenantConfig(adminClient, typedLog.tenant_id);
        const staticVars   = tenantConfig.layout_variables ?? {};
        const rawVars      = (typedLog.template_variables ?? {}) as Record<string, unknown>;
        const perCallVars  = Object.fromEntries(
          Object.entries(rawVars).map(([k, v]) => [k, String(v ?? "")]),
        );

        let finalLogoUrl    = tenantConfig.logo_url;
        let finalTenantName = tenantConfig.tenant_name_fallback ?? "";
        if (typedLog.site_id) {
          const siteOverrides = await getSiteEmailOverrides(adminClient, typedLog.site_id);
          if (siteOverrides) {
            finalLogoUrl    = siteOverrides.logo_url ?? finalLogoUrl;
            finalTenantName = siteOverrides.tenant_name_fallback ?? finalTenantName;
          }
        }

        const logoHtml = finalLogoUrl
          ? `<img src="${finalLogoUrl}" alt="${escapeHtml(finalTenantName || 'Logo')}" style="max-height:60px;width:auto;display:block;">`
          : finalTenantName
            ? `<h1 style="margin:0;font-size:22px;font-weight:bold;">${escapeHtml(finalTenantName)}</h1>`
            : "";

        const layoutNow   = new Date();
        const layoutToday = layoutNow.toISOString().split("T")[0];
        const layoutVars: Record<string, unknown> = {
          ...(staticVars as Record<string, unknown>),
          ...(perCallVars as Record<string, unknown>),
          tenant_name: finalTenantName,
          logo_html:   logoHtml,
          content:     typedLog.html_body,
          globals: {
            today: layoutToday,
            date:  layoutToday,
            year:  String(layoutNow.getFullYear()),
            now:   layoutNow.toISOString(),
          },
        };
        typedLog.html_body = await renderLiquid(resolvedLayoutHtml, layoutVars);
      }
    }

    // 6. Enviar via Resend
    const result = await timedCall(
      feature,
      "resend",
      3000,
      () => sendViaResend(typedLog, msg.idempotency_key, adminClient),
      defaultSlowHandler(feature, "resend", 3000),
    );

    const durationMs = Date.now() - sendStarted;

    // 7. Marcar com a enviat (processing → sent)
    await markSent(
      adminClient,
      msg.email_log_id,
      result.id,
      typedLog.subject,
      typedLog.html_body,
      typedLog.text_body,
    );

    await operationLog.logSuccess({
      tenantId: msg.tenant_id,
      siteId: typedLog.site_id,
      integrationType: "email",
      operationCode: "send_transactional_email",
      title: "Email enviat correctament",
      correlationId: msg.email_log_id,
      durationMs,
      durationThresholdMs: 3000,
      externalService: "resend",
      payloadSummary: {
        subject: typedLog.subject?.slice(0, 80) ?? null,
        resend_id: result.id,
      },
    });

    // QueueRunner: arxivarà + recordarà dedup
    return { success: true };

  } catch (err) {
    const errorMsg = (err as Error).message;
    const durationMs = Date.now() - sendStarted;

    let currentAttempts = typedLog.attempt_count;
    if (errorMsg.includes("template_syntax_error")) {
      currentAttempts = Math.max(currentAttempts, typedLog.max_retries - 1);
    }

    const isDeadLetter = currentAttempts + 1 >= typedLog.max_retries;

    log("error", feature, "Send failed", {
      tenantId: msg.tenant_id,
      correlationId: msg.email_log_id,
      integration: "resend",
      durationMs,
      extra: { error: errorMsg.slice(0, 200) },
    });

    await operationLog.log({
      tenantId: msg.tenant_id,
      siteId: typedLog.site_id,
      integrationType: "email",
      operationCode: "send_transactional_email",
      status: isDeadLetter ? "dead_letter" : "failed",
      title: isDeadLetter ? "Email no enviat (dead letter)" : "No s'ha pogut enviar l'email",
      message: errorMsg.slice(0, 200),
      errorCode: classifyEmailError(errorMsg),
      errorMessage: errorMsg,
      correlationId: msg.email_log_id,
      durationMs,
      durationThresholdMs: 3000,
      externalService: "resend",
      attemptCount: currentAttempts + 1,
      maxAttempts: typedLog.max_retries,
      isRetryable: !isDeadLetter,
      payloadSummary: { subject: typedLog.subject?.slice(0, 80) ?? null },
    });

    if (isInfrastructureBug(err)) {
      captureException(err, {
        feature,
        tenantId: msg.tenant_id,
        correlationId: msg.email_log_id,
      });
    }

    await markFailed(
      adminClient,
      msg.email_log_id,
      errorMsg,
      currentAttempts,
      typedLog.max_retries,
    );

    if (isDeadLetter) {
      return { success: true };
    }

    return { success: false, selfManaged: true };
  }
};

// ---------------------------------------------------------------------------
// Edge Function entry point
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";

  if (!token || token !== SERVICE_ROLE_KEY) {
    log("warn", "process-email-queue", "Unauthorized worker request");
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  // ── 1. Singleton lock (Redis) ──
  const gotLock = await acquireLock();
  if (!gotLock) {
    return new Response(
      JSON.stringify({ status: "skipped", reason: "another worker is running" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const startedAt = Date.now();
  const totalStats: WorkerStats = {
    total: 0,
    succeeded: 0,
    skipped: 0,
    retried: 0,
    dlqed: 0,
    batches: 0,
  };

  try {
    const db = createAdminClient();

    const runner = new QueueRunner({
      queueName: "email_send_queue",
      defaultTask: "send_email",
      handlers: { send_email: sendEmailHandler },
      db,
      maxAttempts: 3,
      batchSize: BATCH_SIZE,
      visibilityTimeoutSec: 300,
    });

    // ── 2. Multi-batch loop (fins a MAX_EXECUTION_MS) ──
    while (Date.now() - startedAt < MAX_EXECUTION_MS) {
      const summary = await runner.runBatch();

      totalStats.total     += summary.total;
      totalStats.succeeded += summary.succeeded;
      totalStats.skipped   += summary.skipped;
      totalStats.retried   += summary.retried;
      totalStats.dlqed     += summary.dlqed;
      totalStats.batches++;

      if (summary.total === 0) break; // Cua buida
    }
  } finally {
    await releaseLock();
    configCache.clear();
  }

  return new Response(
    JSON.stringify({
      status: "completed",
      ...totalStats,
      durationMs: Date.now() - startedAt,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
});

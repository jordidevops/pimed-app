/*
  Edge Function: process-document-pdf-queue
  ─────────────────────────────────────────
  Worker PGMQ per a la cua de generació PDF (document_pdf_queue).

  Utilitza QueueRunner per llegir en batch, processar amb el handler
  convert_to_pdf i gestionar reintentos/DLQ automàticament.

  Handler convert_to_pdf:
    1. Llegeix config Gotenberg (get_pdf_converter_config, cache 60s)
    2. Si pdf_enabled=false → job.skipped + conserva format natiu
    3. Baixa intermediate (HTML/DOCX) de Storage
    4. Crida gotenberg-client (htmlToPdf o docxToPdf)
    5. Puja PDF al DMS, crea document_version, actualitza job
    6. Error de connexió → failed + next_retry_at (backoff exp)
    7. Max retries esgotats → is_dead_letter + notificació owner

  Fair scheduling multi-tenant:
    - Dins del batch, s'agrupen els jobs per tenant i es processen en round-robin.
    - Límit de concurrència global (concurrent_max) i per tenant (per_tenant_max).
*/

import { corsHeaders }              from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { QueueRunner }              from "../_shared/queue-runtime.ts";
import type { TaskPayload, WorkerContext, TaskResult } from "../_shared/queue-runtime.ts";
import { createGotenbergClientFromConfig, GotenbergError } from "../_shared/gotenberg-client.ts";
import { resolveAndPersistFieldMap } from "../_shared/signing-field-map.ts";
import { processAuditCertificateJob } from "../_shared/audit-pdf-job.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { defaultSlowHandler, log, timedCall } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";
import {
  commercialJobIds,
  isCommercialPdfJob,
  persistCommercialRenderedPdf,
} from "../_shared/persist-commercial-pdf.ts";

const FEATURE = "process-document-pdf-queue";
const GOTENBERG_SLOW_MS = 30_000;

// ---------------------------------------------------------------------------
// Caché in-memory de config Gotenberg (60s TTL per instància calenta)
// ---------------------------------------------------------------------------

let configCache: { data: Record<string, unknown>; cachedAt: number } | null = null;
const CONFIG_CACHE_TTL_MS = 60 * 1000;

async function getGotenbergConfig(): Promise<Record<string, unknown>> {
  if (configCache && (Date.now() - configCache.cachedAt) < CONFIG_CACHE_TTL_MS) {
    return configCache.data;
  }
  const apiDb = createAdminClient();
  const { data, error } = await apiDb.rpc("get_pdf_converter_config");
  if (error) throw new Error(`get_pdf_converter_config error: ${error.message}`);
  const cfg = (data ?? {}) as Record<string, unknown>;
  configCache = { data: cfg, cachedAt: Date.now() };
  return cfg;
}

// ---------------------------------------------------------------------------
// Handler: convert_to_pdf
// ---------------------------------------------------------------------------

async function convertToPdf(
  payload: TaskPayload,
  ctx: WorkerContext,
): Promise<TaskResult> {
  const jobId    = payload.payload?.job_id as string | undefined;
  const tenantId = payload.tenant_id;

  if (!jobId) {
    log("error", FEATURE, "Payload missing job_id — routing to DLQ");
    return { success: false };
  }

  // PostgREST només exposa schema api (config.toml); vistes amb GRANT service_role
  const db = ctx.db;
  const operationLog = createOperationLogService(db);
  const now = new Date().toISOString();

  // ── 1. Llegir job de BD ────────────────────────────────────────────────────
  const { data: job, error: jobErr } = await db
    .from("document_pdf_jobs")
    .select("*")
    .eq("id", jobId)
    .eq("tenant_id", tenantId)
    .maybeSingle();

  if (jobErr) {
    log("error", FEATURE, "Job read error", {
      tenantId,
      correlationId: jobId,
      extra: { error: jobErr.message },
    });
    return { success: false, selfManaged: true };
  }
  if (!job) {
    log("error", FEATURE, "Job not found — archiving orphan queue message", {
      tenantId,
      correlationId: jobId,
    });
    return { success: true };
  }

  if (!["queued", "failed"].includes(job.status as string)) {
    log("info", FEATURE, "Job skipped — non-processable status", {
      tenantId,
      correlationId: jobId,
      extra: { status: job.status },
    });
    return { success: true };
  }

  const jobMeta = (job.metadata ?? {}) as Record<string, unknown>;
  if (jobMeta.type === "audit_certificate") {
    try {
      await processAuditCertificateJob(db, job as Record<string, unknown>, {
        jobId,
        tenantId,
        workerId: `audit-${ctx.msgId}`,
      });
      return { success: true };
    } catch (err) {
      const errMsg = (err as Error).message ?? String(err);
      const attempts = ((job.attempt_count as number) ?? 0) + 1;
      const maxRetries = (job.max_retries as number) ?? 5;
      const isDead = attempts >= maxRetries;
      await db.from("document_pdf_jobs").update({
        status: isDead ? "dead_letter" : "failed",
        is_dead_letter: isDead,
        last_error_code: "audit_conversion_error",
        last_error_message: errMsg.slice(0, 1000),
        locked_at: null,
        locked_by: null,
        updated_at: new Date().toISOString(),
      }).eq("id", jobId);
      await operationLog.log({
        tenantId,
        integrationType: "pdf_generation",
        operationCode: "convert_audit_certificate",
        status: isDead ? "dead_letter" : "failed",
        title: isDead ? "Certificat d'auditoria no generat (dead letter)" : "Error generant certificat d'auditoria",
        message: errMsg.slice(0, 200),
        errorCode: "audit_conversion_error",
        errorMessage: errMsg,
        correlationId: jobId,
        sourceJobTable: "document_pdf_jobs",
        sourceJobId: jobId,
        isRetryable: !isDead,
      });
      if (isInfrastructureBug(err)) {
        captureException(err, { feature: FEATURE, tenantId, correlationId: jobId });
      }
      return { success: false, selfManaged: true };
    }
  }

  // ── 2. Llegir config Gotenberg ─────────────────────────────────────────────
  const cfg = await getGotenbergConfig();
  const pdfEnabled = cfg["pdf_enabled"] === true;

  // ── 3. Si pdf_enabled=false → skipped ─────────────────────────────────────
  if (!pdfEnabled) {
    await db
      .from("document_pdf_jobs")
      .update({ status: "skipped", updated_at: now })
      .eq("id", jobId);

    await db.from("document_pdf_events").insert({
      job_id: jobId, event_type: "skipped",
      payload: { reason: "pdf_disabled_by_admin" },
    });
    log("info", FEATURE, "Job skipped (pdf_enabled=false)", { tenantId, correlationId: jobId });
    return { success: true };
  }

  // ── 4. Marcar com a processing ─────────────────────────────────────────────
  await db
    .from("document_pdf_jobs")
    .update({
      status: "processing",
      locked_at: now,
      locked_by: `worker-${ctx.msgId}`,
      attempt_count: (job.attempt_count ?? 0) + 1,
      updated_at: now,
    })
    .eq("id", jobId);

  await db.from("document_pdf_events").insert({
    job_id: jobId, event_type: "processing_started",
    payload: { attempt: (job.attempt_count ?? 0) + 1 },
  });

  const t0 = Date.now();

  try {
    // ── 5. Baixar intermediate de Storage ───────────────────────────────────
    const intermediatePath = job.intermediate_path as string | null;
    if (!intermediatePath) {
      throw new Error("intermediate_path is NULL — cannot convert without rendered content");
    }

    const { data: fileBlob, error: downloadErr } = await db.storage
      .from("documents")
      .download(intermediatePath);

    if (downloadErr || !fileBlob) {
      throw new Error(`Storage download error: ${downloadErr?.message ?? "no blob"}`);
    }

    const fileBytes = new Uint8Array(await fileBlob.arrayBuffer());
    const isDocx = (job.template_type as string) === "docx";
    const outputProfile = (job.output_profile as string) ?? "pdf";

    // ── 6. Cridar Gotenberg ──────────────────────────────────────────────────
    const gotenbergUrl = String(cfg["gotenberg_url"] ?? Deno.env.get("GOTENBERG_URL") ?? "http://host.docker.internal:3007");
    const client = createGotenbergClientFromConfig(cfg);

    let pdfBytes: Uint8Array;
    if (isDocx) {
      const filename = `${job.document_title ?? "document"}.docx`;
      pdfBytes = await timedCall(
        FEATURE,
        "gotenberg",
        GOTENBERG_SLOW_MS,
        () => client.docxToPdf(fileBytes, filename, {
          profile: outputProfile as "pdf" | "pdfa2b" | "pdfa3b",
        }),
        defaultSlowHandler(FEATURE, "gotenberg", GOTENBERG_SLOW_MS),
      );
    } else {
      const htmlContent = new TextDecoder().decode(fileBytes);
      pdfBytes = await timedCall(
        FEATURE,
        "gotenberg",
        GOTENBERG_SLOW_MS,
        () => client.htmlToPdf(htmlContent, {
          profile: outputProfile as "pdf" | "pdfa2b" | "pdfa3b",
        }),
        defaultSlowHandler(FEATURE, "gotenberg", GOTENBERG_SLOW_MS),
      );
    }

    // ── 7. Pujar PDF al DMS ──────────────────────────────────────────────────
    const pdfFileName = `${(job.document_title ?? "document").replace(/[^\w.-]/g, "_")}.pdf`;
    const pdfPath     = `${tenantId}/${crypto.randomUUID()}/${pdfFileName}`;
    const pdfBlob     = new Blob([pdfBytes], { type: "application/pdf" });

    const { error: uploadErr } = await db.storage
      .from("documents")
      .upload(pdfPath, pdfBlob, { contentType: "application/pdf", upsert: false });

    if (uploadErr) throw new Error(`PDF upload error: ${uploadErr.message}`);

    // ── 8. Crear o actualitzar document_version via RPC ──────────────────────
    let resultDocumentId: string | null = null;
    let resultVersionId: string | null  = null;
    const jobAsRecord = job as Record<string, unknown>;

    if (isCommercialPdfJob(jobAsRecord)) {
      const ids = commercialJobIds(jobAsRecord);
      const persisted = await persistCommercialRenderedPdf({
        admin: db,
        tenantId,
        commercialDocumentId: ids.commercialDocumentId,
        title: String(job.document_title ?? "document"),
        createdBy: (job.created_by as string | null) ?? null,
        clientOpId: ids.clientOpId,
        pdfJobId: jobId,
        pdfBytes,
        existingPath: pdfPath,
      });
      resultDocumentId = persisted.documentId;
      resultVersionId = persisted.versionId;
    } else if (job.source_type === "document_existing" && job.result_document_id) {
      // Afegir nova versió al document pare
      const { data: verData, error: verErr } = await db.rpc("add_document_version_internal", {
        p_document_id:      job.result_document_id,
        p_file_path_or_url: pdfPath,
        p_mime_type:        "application/pdf",
        p_size_bytes:       pdfBytes.byteLength,
        p_storage_type:     "native",
      });
      if (verErr) throw new Error(`add_document_version error: ${verErr.message}`);
      resultDocumentId = job.result_document_id as string;
      const parsed = typeof verData === "string" ? JSON.parse(verData) : verData as Record<string, unknown>;
      resultVersionId = (parsed?.version?.id ?? parsed?.id ?? null) as string | null;

    } else {
      // Crear document nou
      const title = job.document_title ?? `PDF-${new Date().toISOString().slice(0, 10)}`;
      const jobMeta = (job.metadata ?? {}) as Record<string, unknown>;
      const category = jobMeta.attendance_protocol === true
        ? "attendance"
        : (typeof jobMeta.category === "string" ? jobMeta.category : null);
      const { data: rpcData, error: rpcErr } = await db.rpc("create_document_with_version_internal", {
        p_tenant_id:        tenantId,
        p_folder_id:        job.folder_id ?? null,
        p_title:            title,
        p_file_path_or_url: pdfPath,
        p_mime_type:        "application/pdf",
        p_size_bytes:       pdfBytes.byteLength,
        p_storage_type:     "native",
        p_created_by:       (job.created_by as string | null) ?? null,
        p_category:         category,
      });
      if (rpcErr || !rpcData) throw new Error(`create_document_with_version error: ${rpcErr?.message}`);
      const created = typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData as Record<string, unknown>;
      const docNode = created?.document as Record<string, unknown> | undefined;
      resultDocumentId = (docNode?.id ?? created?.document_id ?? null) as string | null;
      const verNode = created?.version as Record<string, unknown> | undefined;
      resultVersionId  = (verNode?.id ?? created?.version_id ?? null) as string | null;
    }

    const durationMs = Date.now() - t0;

    // ── 9. Actualitzar job com a completed ───────────────────────────────────
    await db
      .from("document_pdf_jobs")
      .update({
        status:               "completed",
        result_document_id:   resultDocumentId,
        result_version_id:    resultVersionId,
        duration_ms:          durationMs,
        size_input_bytes:     fileBytes.byteLength,
        size_output_bytes:    pdfBytes.byteLength,
        gotenberg_url_used:   gotenbergUrl,
        locked_at:            null,
        locked_by:            null,
        completed_at:         new Date().toISOString(),
        updated_at:           new Date().toISOString(),
      })
      .eq("id", jobId);

    await db.from("document_pdf_events").insert({
      job_id: jobId, event_type: "completed",
      payload: {
        duration_ms: durationMs,
        result_document_id:  resultDocumentId,
        result_version_id:   resultVersionId,
        size_output_bytes:   pdfBytes.byteLength,
        gotenberg_url:       gotenbergUrl,
      },
    });

    // Enllaçar sessions de firma nativa amb la versió PDF generada
    if (resultVersionId) {
      await db
        .from("document_signing_sessions")
        .update({
          document_version_id: resultVersionId,
          updated_at:          new Date().toISOString(),
        })
        .eq("pdf_job_id", jobId)
        .is("result_version_id", null);

      const jobMeta = (job.metadata ?? {}) as Record<string, unknown>;
      if (jobMeta.native_signing === true) {
        const roles = Array.isArray(jobMeta.signature_roles)
          ? (jobMeta.signature_roles as string[])
          : [];
        const fallbackSigners = Array.isArray(jobMeta.fallback_signers)
          ? (jobMeta.fallback_signers as Array<{ role?: string | null; order?: number }>)
          : [];
        const fieldMetas = Array.isArray(jobMeta.field_metas)
          ? (jobMeta.field_metas as Array<{ role: string; name?: string; widthPx?: number; heightPx?: number }>)
          : [];

        await resolveAndPersistFieldMap(db, {
          pdfBytes,
          roles,
          signers:  fallbackSigners,
          fieldMetas,
          pdfJobId: jobId,
        });
      }
    }

    await operationLog.logSuccess({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "convert_to_pdf",
      title: "PDF generat correctament",
      correlationId: jobId,
      durationMs,
      durationThresholdMs: GOTENBERG_SLOW_MS,
      externalService: "gotenberg",
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
      payloadSummary: {
        document_title: (job.document_title as string | null)?.slice(0, 80) ?? null,
        result_document_id: resultDocumentId,
      },
    });

    log("info", FEATURE, "Job completed", {
      tenantId,
      correlationId: jobId,
      durationMs,
      extra: { resultDocumentId },
    });

    const jobMeta = (job.metadata ?? {}) as Record<string, unknown>;
    if (jobMeta.attendance_protocol === true) {
      try {
        await db.rpc("service_enqueue_protocol_finalize_after_pdf", { p_pdf_job_id: jobId });
        const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
        const baseUrl = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
        if (serviceKey && baseUrl) {
          fetch(`${baseUrl}/functions/v1/process-attendance-protocol-publish-queue`, {
            method: "POST",
            headers: { Authorization: `Bearer ${serviceKey}` },
          }).catch(() => undefined);
        }
      } catch (hookErr) {
        log("warn", FEATURE, "Protocol finalize enqueue failed", {
          tenantId,
          correlationId: jobId,
          extra: { error: hookErr instanceof Error ? hookErr.message : String(hookErr) },
        });
      }
    }

    return { success: true };

  } catch (err) {
    const durationMs = Date.now() - t0;
    const errMsg     = (err as Error).message ?? String(err);
    const isGotErr   = err instanceof GotenbergError;
    const errCode    = isGotErr ? err.errorCode : "conversion_error";

    const maxRetries  = (job.max_retries as number) ?? 5;
    const attempts    = ((job.attempt_count as number) ?? 0) + 1;
    const baseSeconds = Number((cfg["retry"] as Record<string, unknown>)?.["backoff_base_seconds"] ?? 60);
    // Backoff exponencial amb jitter (±10%)
    const jitter       = 1 + (Math.random() * 0.2 - 0.1);
    const backoffSec   = Math.min(baseSeconds * Math.pow(2, attempts - 1) * jitter, 3600);
    const nextRetryAt  = new Date(Date.now() + backoffSec * 1000).toISOString();
    const isDead       = attempts >= maxRetries;

    await db
      .from("document_pdf_jobs")
      .update({
        status:                isDead ? "dead_letter" : "failed",
        is_dead_letter:        isDead,
        last_error_code:       errCode,
        last_error_message:    errMsg.slice(0, 1000),
        next_retry_at:         isDead ? null : nextRetryAt,
        duration_ms:           durationMs,
        locked_at:             null,
        locked_by:             null,
        updated_at:            new Date().toISOString(),
      })
      .eq("id", jobId);

    await db.from("document_pdf_events").insert({
      job_id: jobId,
      event_type: isDead ? "dead_letter" : (attempts < maxRetries ? "retry_scheduled" : "failed"),
      payload: {
        attempt:       attempts,
        error_code:    errCode,
        error_message: errMsg.slice(0, 500),
        next_retry_at: isDead ? null : nextRetryAt,
        duration_ms:   durationMs,
      },
    });

    await operationLog.log({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "convert_to_pdf",
      status: isDead ? "dead_letter" : "failed",
      title: isDead ? "PDF no generat (dead letter)" : "Error generant PDF",
      message: errMsg.slice(0, 200),
      errorCode: errCode,
      errorMessage: errMsg,
      correlationId: jobId,
      durationMs,
      durationThresholdMs: GOTENBERG_SLOW_MS,
      externalService: "gotenberg",
      attemptCount: attempts,
      maxAttempts: maxRetries,
      isRetryable: !isDead,
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
    });

    if (isInfrastructureBug(err)) {
      captureException(err, { feature: FEATURE, tenantId, correlationId: jobId });
    }

    log("error", FEATURE, "Job failed", {
      tenantId,
      correlationId: jobId,
      durationMs,
      extra: { errCode, attempt: attempts, maxRetries, error: errMsg.slice(0, 200) },
    });

    // DLQ: notificar owner via move_to_dlq del QueueRunner si arriba aquí
    return { success: isDead ? false : false, selfManaged: !isDead };
  }
}

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName:          "document_pdf_queue",
    handlers:           { convert_to_pdf: convertToPdf },
    db,
    defaultTask:        "convert_to_pdf",
    maxAttempts:        5,
    batchSize:          20,
    visibilityTimeoutSec: 60,
  });

  try {
    const summary = await runner.runBatch();
    if (summary.total === 0) {
      log("info", FEATURE, "Batch empty — no visible PGMQ messages");
    }
    log("info", FEATURE, "Batch done", {
      extra: {
        total: summary.total,
        ok: summary.succeeded,
        retry: summary.retried,
        dlq: summary.dlqed,
      },
    });
    return new Response(JSON.stringify(summary), {
      status:  200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    log("error", FEATURE, "runBatch error", { extra: { error: (err as Error).message } });
    captureException(err, { feature: FEATURE });
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status:  500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

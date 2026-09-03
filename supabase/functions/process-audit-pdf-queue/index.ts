/*
  Edge Function: process-audit-pdf-queue
  Worker alternatiu per jobs audit_certificate (mateixa cua PGMQ).
  El worker principal process-document-pdf-queue també processa auditoria.
*/

import { corsHeaders }       from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { QueueRunner }       from "../_shared/queue-runtime.ts";
import type { TaskPayload, WorkerContext, TaskResult } from "../_shared/queue-runtime.ts";
import { processAuditCertificateJob } from "../_shared/audit-pdf-job.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-audit-pdf-queue";

async function generateAuditPdf(
  payload: TaskPayload,
  ctx: WorkerContext,
): Promise<TaskResult> {
  const jobId    = payload.payload?.job_id as string | undefined;
  const tenantId = payload.tenant_id;
  if (!jobId) return { success: false };

  const db = ctx.db;
  const operationLog = createOperationLogService(db);

  const { data: job, error: jobErr } = await db
    .from("document_pdf_jobs")
    .select("*")
    .eq("id", jobId)
    .eq("tenant_id", tenantId)
    .maybeSingle();

  if (jobErr || !job) return { success: false };
  if (!["queued", "failed"].includes(job.status as string)) return { success: true };

  const meta = (job.metadata ?? {}) as Record<string, unknown>;
  if (meta.type !== "audit_certificate") return { success: true };

  try {
    await processAuditCertificateJob(db, job as Record<string, unknown>, {
      jobId, tenantId, workerId: `audit-${ctx.msgId}`,
    });
    await operationLog.logSuccess({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "generate_audit_certificate",
      title: "Certificat d'auditoria generat",
      correlationId: jobId,
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
    });
    return { success: true };
  } catch (err) {
    const errMsg = (err as Error).message;
    const attempts = ((job.attempt_count as number) ?? 0) + 1;
    const maxRetries = (job.max_retries as number) ?? 5;
    const isDead = attempts >= maxRetries;

    log("error", FEATURE, "Audit PDF generation failed", {
      tenantId,
      correlationId: jobId,
      extra: { error: errMsg, attempt: attempts },
    });

    await operationLog.log({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "generate_audit_certificate",
      status: isDead ? "dead_letter" : "failed",
      title: isDead ? "Certificat d'auditoria no generat (dead letter)" : "Error generant certificat d'auditoria",
      message: errMsg.slice(0, 200),
      errorCode: "audit_conversion_error",
      errorMessage: errMsg,
      correlationId: jobId,
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
      attemptCount: attempts,
      maxAttempts: maxRetries,
      isRetryable: !isDead,
    });

    if (isInfrastructureBug(err)) {
      captureException(err, { feature: FEATURE, tenantId, correlationId: jobId });
    }

    return { success: false, selfManaged: true };
  }
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const db = createAdminClient();
  const runner = new QueueRunner({
    queueName:            "document_pdf_queue",
    handlers:             { convert_to_pdf: generateAuditPdf },
    db,
    defaultTask:          "convert_to_pdf",
    maxAttempts:          3,
    batchSize:            5,
    visibilityTimeoutSec: 300,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return new Response(JSON.stringify(summary), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    log("error", FEATURE, "runBatch error", { extra: { error: (err as Error).message } });
    captureException(err, { feature: FEATURE });
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

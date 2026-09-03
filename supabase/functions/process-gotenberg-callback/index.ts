/*
  Edge Function: process-gotenberg-callback
  ─────────────────────────────────────────
  Webhook endpoint per a callbacks de Gotenberg en mode async.

  Quan process-document-pdf-queue envia una conversió llarga a Gotenberg
  amb callback_url + job_id, Gotenberg crida aquest endpoint al completar.

  Seguretat:
    - Valida signatura HMAC-SHA256 (capçalera X-Gotenberg-Signature)
    - Valida nonce (X-Gotenberg-Nonce) per anti-replay
    - Timestamp màxim 5 minuts (X-Gotenberg-Timestamp)

  Nota: El polling regular continua actiu per robustesa. El webhook accelera
  la notificació per conversions llargues (DOCX/LibreOffice).
*/

import { corsHeaders }       from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-gotenberg-callback";
const GOTENBERG_SLOW_MS = 30_000;

// ---------------------------------------------------------------------------
// HMAC-SHA256 validation
// ---------------------------------------------------------------------------

async function validateHmac(
  secret: string,
  body:   string,
  signature: string,
  timestamp: string,
  nonce: string,
): Promise<boolean> {
  const message = `${timestamp}.${nonce}.${body}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  const expected = Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
  return expected === signature;
}

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const db = createAdminClient();
  const operationLog = createOperationLogService(db);

  const bodyText = await req.text();

  // ── 1. Validar signatura HMAC ────────────────────────────────────────────
  const hmacSecret   = Deno.env.get("GOTENBERG_WEBHOOK_SECRET") ?? "";
  const signature    = req.headers.get("X-Gotenberg-Signature") ?? "";
  const nonce        = req.headers.get("X-Gotenberg-Nonce") ?? "";
  const timestampStr = req.headers.get("X-Gotenberg-Timestamp") ?? "";

  if (hmacSecret) {
    if (!signature || !nonce || !timestampStr) {
      return new Response(JSON.stringify({ error: "missing_signature_headers" }), {
        status:  401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const tsMs = parseInt(timestampStr, 10) * 1000;
    if (isNaN(tsMs) || Math.abs(Date.now() - tsMs) > 5 * 60 * 1000) {
      return new Response(JSON.stringify({ error: "timestamp_expired" }), {
        status:  401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const valid = await validateHmac(hmacSecret, bodyText, signature, timestampStr, nonce);
    if (!valid) {
      return new Response(JSON.stringify({ error: "invalid_signature" }), {
        status:  401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  // ── 2. Parsejar body ─────────────────────────────────────────────────────
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(bodyText);
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status:  400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const jobId    = body.job_id as string | undefined;
  const tenantId = body.tenant_id as string | undefined;
  const success  = body.success as boolean | undefined;
  const pdfBase64 = body.pdf_base64 as string | undefined;
  const errorMsg  = body.error as string | undefined;

  if (!jobId || !tenantId) {
    return new Response(JSON.stringify({ error: "missing_job_id_or_tenant_id" }), {
      status:  400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // ── 3. Llegir job de BD ──────────────────────────────────────────────────
  const { data: job, error: jobErr } = await db
    .from("document_pdf_jobs")
    .select("*")
    .eq("id", jobId)
    .eq("tenant_id", tenantId)
    .maybeSingle();

  if (jobErr || !job) {
    log("error", FEATURE, "Job not found", { tenantId, correlationId: jobId, extra: { error: jobErr?.message } });
    return new Response(JSON.stringify({ error: "job_not_found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const now = new Date().toISOString();
  const t0 = Date.now();

  // ── 4. Error en la conversió ─────────────────────────────────────────────
  if (!success || !pdfBase64) {
    const attempts   = ((job.attempt_count as number) ?? 0) + 1;
    const maxRetries = (job.max_retries as number) ?? 5;
    const isDead     = attempts >= maxRetries;
    const msg = (errorMsg ?? "Gotenberg callback returned error").slice(0, 1000);

    await db
      .from("document_pdf_jobs")
      .update({
        status:             isDead ? "dead_letter" : "failed",
        is_dead_letter:     isDead,
        last_error_code:    "conversion_error",
        last_error_message: msg,
        locked_at:          null,
        locked_by:          null,
        updated_at:         now,
      })
      .eq("id", jobId);

    await db.from("document_pdf_events").insert({
      job_id: jobId, event_type: isDead ? "dead_letter" : "failed",
      payload: { source: "callback", error_message: errorMsg, attempt: attempts },
    });

    await operationLog.log({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "gotenberg_callback",
      status: isDead ? "dead_letter" : "failed",
      title: isDead ? "PDF no generat (dead letter)" : "Error de conversió Gotenberg (callback)",
      message: msg.slice(0, 200),
      errorCode: "conversion_error",
      errorMessage: msg,
      correlationId: jobId,
      externalService: "gotenberg",
      attemptCount: attempts,
      maxAttempts: maxRetries,
      isRetryable: !isDead,
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
    });

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // ── 5. Processar PDF rebut ───────────────────────────────────────────────
  try {
    const pdfBytes = Uint8Array.from(atob(pdfBase64), c => c.charCodeAt(0));
    const pdfFileName = `${(job.document_title as string ?? "document").replace(/[^\w.-]/g, "_")}.pdf`;
    const pdfPath = `${tenantId}/${crypto.randomUUID()}/${pdfFileName}`;

    const { error: uploadErr } = await db.storage
      .from("documents")
      .upload(pdfPath, new Blob([pdfBytes], { type: "application/pdf" }), {
        contentType: "application/pdf",
        upsert: false,
      });

    if (uploadErr) throw new Error(`PDF upload error: ${uploadErr.message}`);

    let resultDocumentId: string | null = null;
    let resultVersionId: string | null  = null;

    if (job.source_type === "document_existing" && job.result_document_id) {
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
      const { data: rpcData, error: rpcErr } = await db.rpc("create_document_with_version_internal", {
        p_tenant_id:        tenantId,
        p_folder_id:        job.folder_id ?? null,
        p_title:            job.document_title ?? `PDF-${new Date().toISOString().slice(0, 10)}`,
        p_file_path_or_url: pdfPath,
        p_mime_type:        "application/pdf",
        p_size_bytes:       pdfBytes.byteLength,
        p_storage_type:     "native",
        p_created_by:       (job.created_by as string | null) ?? null,
      });
      if (rpcErr || !rpcData) throw new Error(`create_document error: ${rpcErr?.message}`);
      const created = typeof rpcData === "string" ? JSON.parse(rpcData) : rpcData as Record<string, unknown>;
      const docNode = created?.document as Record<string, unknown> | undefined;
      resultDocumentId = (docNode?.id ?? created?.document_id ?? null) as string | null;
      const verNode = created?.version as Record<string, unknown> | undefined;
      resultVersionId  = (verNode?.id ?? created?.version_id ?? null) as string | null;
    }

    const durationMs = Date.now() - t0;

    await db
      .from("document_pdf_jobs")
      .update({
        status:              "completed",
        result_document_id:  resultDocumentId,
        result_version_id:   resultVersionId,
        size_output_bytes:   pdfBytes.byteLength,
        duration_ms:         durationMs,
        locked_at:           null,
        locked_by:           null,
        completed_at:        now,
        updated_at:          now,
      })
      .eq("id", jobId);

    await db.from("document_pdf_events").insert({
      job_id: jobId, event_type: "completed",
      payload: {
        source: "callback",
        result_document_id: resultDocumentId,
        result_version_id:  resultVersionId,
        size_output_bytes:  pdfBytes.byteLength,
        duration_ms:        durationMs,
      },
    });

    await operationLog.logSuccess({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "gotenberg_callback",
      title: "PDF generat via callback Gotenberg",
      correlationId: jobId,
      durationMs,
      durationThresholdMs: GOTENBERG_SLOW_MS,
      externalService: "gotenberg",
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
      payloadSummary: {
        result_document_id: resultDocumentId,
        source: "callback",
      },
    });

    log("info", FEATURE, "Job completed via callback", {
      tenantId,
      correlationId: jobId,
      durationMs,
      extra: { resultDocumentId },
    });
  } catch (err) {
    const errMsg = (err as Error).message;
    log("error", FEATURE, "Post-processing error", {
      tenantId,
      correlationId: jobId,
      extra: { error: errMsg },
    });

    await db.from("document_pdf_events").insert({
      job_id: jobId, event_type: "failed",
      payload: { source: "callback_post_processing", error: errMsg },
    });

    await operationLog.log({
      tenantId,
      integrationType: "pdf_generation",
      operationCode: "gotenberg_callback",
      status: "failed",
      title: "Error processant PDF rebut de Gotenberg",
      message: errMsg.slice(0, 200),
      errorCode: "callback_post_processing",
      errorMessage: errMsg,
      correlationId: jobId,
      externalService: "gotenberg",
      isRetryable: true,
      sourceJobTable: "document_pdf_jobs",
      sourceJobId: jobId,
    });

    if (isInfrastructureBug(err)) {
      captureException(err, { feature: FEATURE, tenantId, correlationId: jobId });
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    status:  200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});

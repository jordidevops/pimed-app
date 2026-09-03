/*
  Edge Function: docuseal-webhook
  ────────────────────────────────
  Endpoint públic (verify_jwt=false) que rep events de DocuSeal i sincronitza
  l'estat de les submissions, el timeline d'events i el PDF final al DMS.

  SEGURETAT: cada petició es verifica amb HMAC-SHA256 usant el secret configurat
  a DOCUSEAL_WEBHOOK_SECRET. La signatura arriba a la capçalera X-DocuSeal-Signature.

  Idempotència estricta:
    · append_signing_event (RPC) fa ON CONFLICT DO NOTHING per webhook_event_id.
    · El PDF final es puja només si no existeix ja una versió amb el mateix
      docuseal_submission_id i status=completed.

  Events suportats:
    · form.viewed, form.started, form.completed, form.declined  → status de signant
    · submission.completed                                       → PDF final + DMS
    · submission.expired, submission.declined                    → estat final
    · Qualsevol altre event → loguem i retornem 200 (sense reintents innecessaris)

  Testeig local:
    supabase functions serve docuseal-webhook --env-file supabase/functions/.env.local
*/

import { createAdminClient, createAdminDataClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "docuseal-webhook";

// ---------------------------------------------------------------------------
// Entorn
// ---------------------------------------------------------------------------

const DOCUSEAL_WEBHOOK_SECRET      = Deno.env.get("DOCUSEAL_WEBHOOK_SECRET") ?? "";
const DOCUSEAL_API_URL_ENV         = Deno.env.get("DOCUSEAL_API_URL") ?? "https://api.docuseal.eu";
// URL base per a les URLs de signatura dels signants (sense el prefix 'api.')
// api.docuseal.eu → docuseal.eu | api.docuseal.com → docuseal.com
const DOCUSEAL_SIGNING_BASE_URL    = DOCUSEAL_API_URL_ENV.replace("://api.", "://");
const DOCUSEAL_SKIP_SIG            = Deno.env.get("DOCUSEAL_SKIP_WEBHOOK_SIGNATURE") === "true";
const DOCUMENTS_BUCKET             = "documents";

// ---------------------------------------------------------------------------
// Tipus DocuSeal webhook payload
// ---------------------------------------------------------------------------

interface DocusealSubmitter {
  id:          number;
  uuid:        string;
  email:       string;
  name?:       string;
  role?:       string;
  external_id?: string;
  status?:     string;
  slug?:       string;
  opened_at?:  string;
  completed_at?: string;
}

interface DocusealDocument {
  id?:  number;
  name: string;
  url:  string;
}

interface DocusealSubmissionSummary {
  id?:                  number;
  status?:              string;
  url?:                 string;
  combined_document_url?: string | null;
  audit_log_url?:       string | null;
}

interface DocusealEventData {
  id:           number;
  external_id?: string;
  application_key?: string;
  status?:      string;
  submitters?:  DocusealSubmitter[];
  documents?:   DocusealDocument[];
  submission?:  DocusealSubmissionSummary;
  // URL directa del PDF d'auditoria (present a submission.completed)
  audit_log_url?: string | null;
  // Per events de form.*, data ÉS el submitter directe (no hi ha array submitters)
  email?:       string;
  name?:        string;
  uuid?:        string;
  slug?:        string;
  opened_at?:   string | null;
  completed_at?: string | null;
}

interface DocusealPayload {
  event_type: string;
  timestamp:  string;
  data:       DocusealEventData;
}

function normalizeDocusealPayload(rawBody: string, contentType: string | null): DocusealPayload | null {
  const body = rawBody.trim();
  if (!body) return null;

  const parseJson = (value: string): unknown => {
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  };

  let parsed: unknown = parseJson(body);

  // Alguns emissors de webhook envien application/x-www-form-urlencoded
  // amb una clau "payload" que conté JSON serialitzat.
  if (
    !parsed &&
    (contentType?.includes("application/x-www-form-urlencoded") || body.startsWith("payload="))
  ) {
    const params = new URLSearchParams(body);
    const payloadRaw = params.get("payload");
    if (payloadRaw) {
      parsed = parseJson(payloadRaw);
    }
  }

  if (!parsed || typeof parsed !== "object") {
    return null;
  }

  const rec = parsed as Record<string, unknown>;
  const eventType = typeof rec.event_type === "string" ? rec.event_type : null;
  const data = (rec.data && typeof rec.data === "object") ? rec.data as DocusealEventData : null;
  const timestamp = typeof rec.timestamp === "string" ? rec.timestamp : new Date().toISOString();

  if (!eventType || !data) {
    return null;
  }

  return {
    event_type: eventType,
    data,
    timestamp,
  };
}

// ---------------------------------------------------------------------------
// Verificació HMAC-SHA256 (capçalera X-DocuSeal-Signature)
// ---------------------------------------------------------------------------

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function verifySignature(rawBody: string, headers: Headers, secret: string): Promise<boolean> {
  if (!secret) return false;

  const signature = headers.get("X-DocuSeal-Signature") ?? headers.get("x-docuseal-signature");
  if (!signature) {
    log("error", FEATURE, "Missing X-DocuSeal-Signature header");
    return false;
  }

  const encoder      = new TextEncoder();
  const keyBytes     = encoder.encode(secret);
  const bodyBytes    = encoder.encode(rawBody);

  const cryptoKey = await crypto.subtle.importKey(
    "raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signatureBuffer = await crypto.subtle.sign("HMAC", cryptoKey, bodyBytes);
  const computed = Array.from(new Uint8Array(signatureBuffer))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");

  return timingSafeEqual(signature, computed);
}

// ---------------------------------------------------------------------------
// Helpers de resposta
// ---------------------------------------------------------------------------

function jsonOk(body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Mapeig event DocuSeal → status intern
// ---------------------------------------------------------------------------

const EVENT_TO_STATUS: Record<string, string | null> = {
  "form.viewed":          null,            // no canvia l'estat de la submission
  "form.started":         null,
  "form.completed":       null,            // el signant individual ha completat (no la submission)
  "form.declined":        null,
  "submission.completed": "completed",
  "submission.expired":   "expired",
  "submission.declined":  "declined",
  "submission.created":   "in_progress",
};

const FINAL_SIGNER_STATUSES = new Set([
  "completed",
  "declined",
  "expired",
  "cancelled",
  "error",
  "signed",
]);

type SubmissionSignerSnapshot = {
  email?: string | null;
  status?: string | null;
  completed_at?: string | null;
};

function isTerminalFormDecline(
  eventType: string,
  signerEmail: string | null | undefined,
  currentSigners: unknown,
): boolean {
  if (eventType !== "form.declined") return false;

  // Si no tenim snapshot de signants, preferim tancar com declined:
  // DocuSeal pot no enviar submission.declined en alguns fluxos.
  if (!Array.isArray(currentSigners) || currentSigners.length === 0) {
    return true;
  }

  const emailLc = signerEmail?.toLowerCase() ?? null;
  const normalized = (currentSigners as SubmissionSignerSnapshot[]).map((signer) => {
    const signerMatches =
      !!emailLc &&
      typeof signer.email === "string" &&
      signer.email.toLowerCase() === emailLc;

    if (signerMatches) return "declined";
    if (signer.completed_at) return "completed";
    return (signer.status ?? "").toLowerCase();
  });

  const hasDeclined = normalized.some((status) => status === "declined");
  const hasNonFinal = normalized.some((status) => !FINAL_SIGNER_STATUSES.has(status));
  return hasDeclined && !hasNonFinal;
}

// ---------------------------------------------------------------------------
// Helpers de ruta Storage
// ---------------------------------------------------------------------------

/**
 * Calcula el path del PDF firmat/audit al costat de l'arxiu original.
 * originalPath = "{tenant_id}/{file_uuid}/{safe_name.ext}"
 * Retorna "{tenant_id}/{file_uuid}/{safe_name}{suffix}.pdf"
 * Fallback si no hi ha original: "{tenant_id}/{folder}/{submissionId}{suffix}.pdf"
 */
function computeNeighborPath(
  tenantId:     string,
  submissionId: string,
  originalPath: string | null,
  suffix:       "_signed" | "_audit",
): string {
  if (originalPath) {
    const segments = originalPath.split("/");
    if (segments.length >= 3) {
      const fileUuid = segments[1];
      const fileName = segments.slice(2).join("/");
      const dotIdx   = fileName.lastIndexOf(".");
      const baseName = dotIdx >= 0 ? fileName.slice(0, dotIdx) : fileName;
      return `${tenantId}/${fileUuid}/${baseName}${suffix}.pdf`;
    }
  }
  const folder = suffix === "_signed" ? "signed" : "audit";
  return `${tenantId}/${folder}/${submissionId}${suffix}.pdf`;
}

async function logSigningOperationFailure(
  adminClient: ReturnType<typeof createAdminClient>,
  params: {
    tenantId: string;
    submissionId: string;
    operationCode: string;
    title: string;
    message: string;
    errorCode?: string;
    err?: unknown;
  },
): Promise<void> {
  const operationLog = createOperationLogService(adminClient);
  await operationLog.log({
    tenantId: params.tenantId,
    integrationType: "signing",
    operationCode: params.operationCode,
    status: "failed",
    title: params.title,
    message: params.message.slice(0, 200),
    errorCode: params.errorCode,
    errorMessage: params.message,
    correlationId: params.submissionId,
    entityType: "signing_submission",
    entityId: params.submissionId,
    externalService: "docuseal",
    isRetryable: false,
  });
  if (params.err && isInfrastructureBug(params.err)) {
    captureException(params.err, {
      feature: FEATURE,
      tenantId: params.tenantId,
      correlationId: params.submissionId,
    });
  }
}


async function attachSignedDocument(
  adminClient:   ReturnType<typeof createAdminClient>,
  submissionId:  string,
  tenantId:      string,
  documentUrl:   string,
  documentName:  string,
): Promise<void> {

  // Guard idempotent: si ja tenim versió final, no reprocessem
  const { data: currentSubmission } = await adminClient
    .from("signing_submissions")
    .select("result_document_version_id")
    .eq("id", submissionId)
    .maybeSingle();

  if (currentSubmission?.result_document_version_id) {
    log("info", FEATURE, "Signed PDF already attached, skipping", {
      correlationId: submissionId,
    });
    return;
  }

  // Descarregar PDF de DocuSeal
  let fileData: Uint8Array;
  try {
    const res = await fetch(documentUrl);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    fileData = new Uint8Array(await res.arrayBuffer());
  } catch (err) {
    const msg = (err as Error).message;
    log("error", FEATURE, "Error descarregant PDF firmat", {
      tenantId,
      correlationId: submissionId,
      extra: { error: msg },
    });
    await logSigningOperationFailure(adminClient, {
      tenantId,
      submissionId,
      operationCode: "attach_signed_pdf",
      title: "No s'ha pogut descarregar el PDF firmat",
      message: msg,
      errorCode: "download_failed",
      err,
    });
    return;
  }

  // Obtenir source_document_version_id de la submission
  const { data: sub, error: subErr } = await adminClient
    .from("signing_submissions")
    .select("source_document_version_id")
    .eq("id", submissionId)
    .single();

  if (subErr || !sub) {
    log("error", FEATURE, "Submission not found for PDF attach", {
      correlationId: submissionId,
    });
    return;
  }

  // Obtenir document pare i path original des de document_versions (fix per query fragile)
  let documentId:   string | null = null;
  let originalPath: string | null = null;

  if (sub.source_document_version_id) {
    // Usem el client de data.* perquè api.document_versions no existeix com a vista
    const dataClient = createAdminDataClient();
    const { data: srcVer } = await dataClient
      .from("document_versions")
      .select("document_id, file_path_or_url")
      .eq("id", sub.source_document_version_id)
      .maybeSingle();

    documentId   = (srcVer?.document_id   as string | undefined) ?? null;
    originalPath = (srcVer?.file_path_or_url as string | undefined) ?? null;
  }

  if (!documentId) {
    // Plantilla o document sense versió font: crear document contenidor directament
    // (no usem create_document_with_version RPC perquè comprova jwt_user_tenants)
    const safeName = documentName.replace(/[^\w.\-]/g, "_").slice(0, 200);
    const dataClient = createAdminDataClient();
    const { data: newDoc, error: docErr } = await dataClient
      .from("documents")
      .insert({ tenant_id: tenantId, title: `Signed - ${safeName}` })
      .select("id")
      .single();

    if (docErr || !newDoc?.id) {
      const msg = docErr?.message ?? "unknown";
      log("error", FEATURE, "Error creant document contenidor", {
        tenantId,
        correlationId: submissionId,
        extra: { error: msg },
      });
      await logSigningOperationFailure(adminClient, {
        tenantId,
        submissionId,
        operationCode: "attach_signed_pdf",
        title: "No s'ha pogut crear el document per al PDF firmat",
        message: msg,
        errorCode: "document_create_failed",
      });
      return;
    }
    documentId = newDoc.id as string;
  }

  // Ruta al costat de l'original (o fallback a carpeta "signed/")
  const path = computeNeighborPath(tenantId, submissionId, originalPath, "_signed");
  const blob = new Blob([fileData.buffer as ArrayBuffer], { type: "application/pdf" });

  const { error: uploadErr } = await adminClient.storage
    .from(DOCUMENTS_BUCKET)
    .upload(path, blob, { contentType: "application/pdf", upsert: false });

  if (uploadErr) {
    const msg = uploadErr.message.toLowerCase();
    if (!msg.includes("already exists") && !msg.includes("duplicate")) {
      log("error", FEATURE, "Error pujant PDF firmat", {
        tenantId,
        correlationId: submissionId,
        extra: { error: uploadErr.message },
      });
      await logSigningOperationFailure(adminClient, {
        tenantId,
        submissionId,
        operationCode: "attach_signed_pdf",
        title: "No s'ha pogut pujar el PDF firmat",
        message: uploadErr.message,
        errorCode: "upload_failed",
      });
      return;
    }
  }

  // Reutilitzar versió si ja apunta al mateix path (idempotència)
  const { data: existingVersion } = await adminClient
    .from("document_versions")
    .select("id")
    .eq("file_path_or_url", path)
    .maybeSingle();

  if (existingVersion?.id) {
    await adminClient
      .from("signing_submissions")
      .update({ result_document_version_id: existingVersion.id })
      .eq("id", submissionId)
      .eq("tenant_id", tenantId);
    return;
  }

  // Crear versió nova al DMS
  // Usem add_document_version_internal (sense check jwt_user_tenants) perquè
  // el webhook opera amb service_role i no té JWT d'usuari → la RPC estàndard
  // retornaria "Acces denegat: cal rol owner o manager".
  const { data: verData, error: verErr } = await adminClient.rpc("add_document_version_internal", {
    p_document_id:      documentId,
    p_file_path_or_url: path,
    p_mime_type:        "application/pdf",
    p_size_bytes:       fileData.length,
    p_storage_type:     "native",
  });

  if (verErr) {
    log("error", FEATURE, "Error creant versió DMS", {
      tenantId,
      correlationId: submissionId,
      extra: { error: verErr.message },
    });
    await logSigningOperationFailure(adminClient, {
      tenantId,
      submissionId,
      operationCode: "attach_signed_pdf",
      title: "No s'ha pogut registrar el PDF firmat al DMS",
      message: verErr.message,
      errorCode: "version_create_failed",
    });
    return;
  }

  const parsedVer = typeof verData === "string" ? JSON.parse(verData) : verData;
  const versionId = (parsedVer as Record<string, unknown>).id as string | undefined;

  if (versionId) {
    await adminClient
      .from("signing_submissions")
      .update({ result_document_version_id: versionId })
      .eq("id", submissionId)
      .eq("tenant_id", tenantId);
  }

  log("info", FEATURE, "Signed PDF attached", {
    tenantId,
    correlationId: submissionId,
    extra: { document_id: documentId, version_id: versionId, path },
  });
}

// ---------------------------------------------------------------------------
// Descarregar PDF d'auditoria i desar path a signing_submissions
// ---------------------------------------------------------------------------

async function attachAuditDocument(
  adminClient:    ReturnType<typeof createAdminClient>,
  submissionId:   string,
  tenantId:       string,
  documents:      DocusealDocument[],
  directAuditUrl: string | null = null,
): Promise<void> {
  // Guard idempotent: si ja tenim audit_trail_storage_path, no reprocessem
  const { data: current } = await adminClient
    .from("signing_submissions")
    .select("audit_trail_storage_path, source_document_version_id")
    .eq("id", submissionId)
    .maybeSingle();

  if (current?.audit_trail_storage_path) {
    log("info", FEATURE, "Audit PDF already attached, skipping", {
      correlationId: submissionId,
    });
    return;
  }

  // Prioritat 1: URL directa de DocuSeal (audit_log_url del payload)
  // Prioritat 2: detectar per nom dins l'array documents[]
  // Prioritat 3: fallback al segon document (DocuSeal sol posar l'audit al índex 1)
  let auditUrl: string | null = directAuditUrl ?? null;

  if (!auditUrl) {
    log("debug", FEATURE, "Documents received for audit lookup", {
      correlationId: submissionId,
      extra: { documents: documents.map(d => ({ name: d.name, hasUrl: !!d.url })) },
    });

    let auditDoc: DocusealDocument | undefined;
    for (const doc of documents) {
      const nameLower = (doc.name ?? "").toLowerCase();
      if (nameLower.includes("audit") || nameLower.includes("certificate") || nameLower.includes("trail")) {
        auditDoc = doc;
        break;
      }
    }
    if (!auditDoc && documents.length > 1) auditDoc = documents[1];
    auditUrl = auditDoc?.url ?? null;
  }

  if (!auditUrl) {
    log("info", FEATURE, "No audit URL detected", {
      correlationId: submissionId,
      extra: { document_count: documents.length, direct_audit_url: directAuditUrl ?? null },
    });
    return;
  }

  log("info", FEATURE, "Downloading audit PDF", {
    correlationId: submissionId,
    extra: { audit_url_prefix: auditUrl.slice(0, 60) },
  });

  // Obtenir path original per situar l'audit al costat del document font
  // (usem el client de data.* perquè api.document_versions no existeix com a vista)
  let originalPath: string | null = null;
  if (current?.source_document_version_id) {
    const dataClient = createAdminDataClient();
    const { data: srcVer } = await dataClient
      .from("document_versions")
      .select("file_path_or_url")
      .eq("id", current.source_document_version_id)
      .maybeSingle();

    originalPath = (srcVer?.file_path_or_url as string | undefined) ?? null;
  }

  // Descarregar a Storage (best-effort: si falla el frontend pot usar audit_log_url)
  let fileData: Uint8Array;
  try {
    const res = await fetch(auditUrl);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    fileData = new Uint8Array(await res.arrayBuffer());
  } catch (err) {
    log("error", FEATURE, "Error downloading audit PDF (audit_log_url saved as fallback)", {
      correlationId: submissionId,
      extra: { error: (err as Error).message },
    });
    return;
  }

  const path = computeNeighborPath(tenantId, submissionId, originalPath, "_audit");
  const blob = new Blob([fileData.buffer as ArrayBuffer], { type: "application/pdf" });

  const { error: uploadErr } = await adminClient.storage
    .from(DOCUMENTS_BUCKET)
    .upload(path, blob, { contentType: "application/pdf", upsert: false });

  if (uploadErr) {
    const msg = uploadErr.message.toLowerCase();
    if (!msg.includes("already exists") && !msg.includes("duplicate")) {
      log("error", FEATURE, "Error uploading audit PDF", {
        correlationId: submissionId,
        extra: { error: uploadErr.message },
      });
      return;
    }
    // Si ja existia, igualment actualitzem el path
  }

  await adminClient
    .from("signing_submissions")
    .update({ audit_trail_storage_path: path })
    .eq("id", submissionId)
    .eq("tenant_id", tenantId);

  log("info", FEATURE, "Audit PDF attached", {
    correlationId: submissionId,
    extra: { path },
  });
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method !== "POST") {
    return errorResponse(405, "Method Not Allowed");
  }

  const rawBody = await req.text();

  if (!DOCUSEAL_WEBHOOK_SECRET && !DOCUSEAL_SKIP_SIG) {
    log("error", FEATURE, "DOCUSEAL_WEBHOOK_SECRET not configured");
    return errorResponse(500, "Server misconfiguration");
  }

  // ── 1. Verificació HMAC ───────────────────────────────────────────────────
  if (DOCUSEAL_SKIP_SIG) {
    // Bypass per a entorn local/dev on DocuSeal test mode no envia signatura
    log("warn", FEATURE, "HMAC verification disabled (DOCUSEAL_SKIP_WEBHOOK_SIGNATURE=true)");
  } else {
    const isValid = await verifySignature(rawBody, req.headers, DOCUSEAL_WEBHOOK_SECRET);
    if (!isValid) {
      return errorResponse(401, "Unauthorized — invalid signature");
    }
  }

  // ── 2. Parseig del payload ────────────────────────────────────────────────
  const payload = normalizeDocusealPayload(rawBody, req.headers.get("content-type"));
  if (!payload) {
    const preview = rawBody.slice(0, 200).replace(/\s+/g, " ").trim();
    log("warn", FEATURE, "Unsupported webhook payload", {
      extra: {
        content_type: req.headers.get("content-type") ?? "?",
        body_preview: preview,
      },
    });
    return jsonOk({ received: true, processed: false, reason: "unsupported_payload" });
  }

  const { event_type, data } = payload;
  const webhookEventId       = `${event_type}:${data.id ?? ""}:${data.uuid ?? payload.timestamp ?? ""}`;

  // Per form.* events: data.external_id és l'external_id del submitter (format: "{submissionExtId}:s{idx}").
  // Per submission.* events: data.external_id és null.
  // BUG-1 FIX: extreure el submissionExternalId stripejant el sufix ":sN"
  const rawExtId: string | null =
    (data.external_id ?? null) ||
    (data.application_key ?? null) ||
    (data.submitters?.[0]?.external_id ?? null) ||
    null;

  // Strip del sufix per obtenir l'external_id de la submission
  const submissionExternalId: string | null = rawExtId
    ? rawExtId.replace(/:s\d+$/, '')
    : null;
  // Extreure l'índex del signant per a la notificació seqüencial
  const signerOrderFromExtId: number = rawExtId
    ? (parseInt(rawExtId.match(/:s(\d+)$/)?.[1] ?? '-1', 10))
    : -1;

  // Compatibilitat cap enrere: si no té sufix ":sN", el rawExtId és directament l'external_id
  const externalId = submissionExternalId ?? rawExtId;

  const submissionStatus = data.submission?.status ?? null;
  const isFormCompletedWithSubmissionCompleted =
    event_type === "form.completed" && submissionStatus === "completed";

  log("info", FEATURE, "Webhook event received", {
    correlationId: externalId ?? undefined,
    extra: {
      event_type,
      ds_id: data.id,
      has_docs: (data.documents?.length ?? 0) > 0,
      submission_status: submissionStatus ?? "?",
    },
  });

  // ── 3. Localitzar submission per external_id ──────────────────────────────
  if (!externalId) {
    log("warn", FEATURE, "Event without external_id ignored", {
      extra: { event_type, ds_id: data.id },
    });
    return jsonOk({ received: true, processed: false, reason: "no_external_id" });
  }

  const adminClient = createAdminClient();

  const { data: submission, error: subErr } = await adminClient
    .from("signing_submissions")
    .select("id, tenant_id, status, signers, notification_mode")
    .eq("external_id", externalId)
    .maybeSingle();

  if (subErr || !submission) {
    log("warn", FEATURE, "external_id not found (possible race condition)", {
      extra: { external_id: data.external_id },
    });
    return errorResponse(404, "Submission not found");
  }

  // Ignorar events sobre submissions ja tancades (idempotència d'estat final)
  const FINAL_STATUSES = ["completed", "declined", "expired", "cancelled", "error"];
  const shouldProcessAsCompleted = event_type === "submission.completed" || isFormCompletedWithSubmissionCompleted;
  const isFormDeclinedWithSubmissionDeclined =
    event_type === "form.declined" && submissionStatus === "declined";
  const isFormDeclinedTerminal = isTerminalFormDecline(
    event_type,
    data.email ?? null,
    submission.signers,
  );
  const statusAfter = shouldProcessAsCompleted
    ? "completed"
    : (isFormDeclinedWithSubmissionDeclined || isFormDeclinedTerminal)
      ? "declined"
    : EVENT_TO_STATUS[event_type];

  if (
    FINAL_STATUSES.includes(submission.status as string) &&
    !shouldProcessAsCompleted // sempre processar completed per adjuntar PDF si falta
  ) {
    log("info", FEATURE, "Submission already in final status, event ignored", {
      correlationId: submission.id as string,
      extra: { status: submission.status },
    });
    return jsonOk({ received: true, processed: false, reason: "already_final" });
  }

  // ── 4. Persistir event via RPC (service_role, idempotent) ─────────────────
  const signerEmail = data.email ?? data.submitters?.[0]?.email ?? null;
  const signerName  = data.name  ?? data.submitters?.[0]?.name  ?? null;

  const { error: eventErr } = await adminClient.rpc("append_signing_event", {
    p_submission_id:    submission.id,
    p_event_type:       event_type,
    p_event_source:     "webhook",
    p_webhook_event_id: webhookEventId,
    p_signer_email:     signerEmail,
    p_signer_name:      signerName,
    p_status_before:    submission.status,
    p_status_after:     statusAfter ?? null,
    p_payload:          data as unknown as Record<string, unknown>,
  });

  if (eventErr) {
    log("error", FEATURE, "append_signing_event error", {
      correlationId: submission.id as string,
      extra: { error: eventErr.message },
    });
    // No retornem error per no provocar reintents innecessaris de DocuSeal
  }

  // ── 5. Actualitzar snapshot de signants ─────────────────────────────────
  if (data.submitters && data.submitters.length > 0) {
    // submission.completed: DocuSeal envia l'array complet de submitters
    const signers = data.submitters.map((s, idx) => {
      // Extreure signer_order del external_id (:s{N} sufix) per no dependre de l'ordre de l'array
      const orderMatch = (s.external_id ?? '').match(/:s(\d+)$/);
      const order = orderMatch ? parseInt(orderMatch[1], 10) : idx;
      return {
        email:        s.email,
        name:         s.name ?? "",
        role:         s.role ?? "",
        status:       s.status ?? "pending",
        // DOCUSEAL_SIGNING_BASE_URL: api.docuseal.eu → docuseal.eu (domini de signatura, no d'API)
        signing_url:  s.slug ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${s.slug}` : null,
        completed_at: s.completed_at ?? null,
        opened_at:    s.opened_at ?? null,
        order,
      };
    });

    await adminClient
      .from("signing_submissions")
      .update({ signers: signers as unknown as never })
      .eq("id", submission.id)
      .eq("tenant_id", submission.tenant_id as string);

  } else if (event_type?.startsWith("form.") && data.email) {
    // form.completed / form.declined / form.opened: data ÉS el submitter directe.
    // No hi ha array submitters → actualitzar únicament el signer corresponent per email.
    type SignerRecord = {
      email: string; name: string; role: string;
      status: string; signing_url: string | null;
      completed_at: string | null; opened_at: string | null;
    };
    const currentSigners = Array.isArray(submission.signers)
      ? (submission.signers as unknown as SignerRecord[])
      : [];

    const signerStatus: string =
      data.status ?? (event_type === "form.completed" ? "completed" :
                      event_type === "form.declined" ? "declined" : "opened");

    const updatedSigners = currentSigners.map(s => {
      if (s.email !== data.email) return s;
      return {
        ...s,
        status:       signerStatus,
        completed_at: event_type === "form.completed" ? (data.completed_at ?? s.completed_at) : s.completed_at,
        opened_at:    data.opened_at ?? s.opened_at,
        signing_url:  data.slug ? `${DOCUSEAL_SIGNING_BASE_URL}/s/${data.slug}` : s.signing_url,
      };
    });

    if (currentSigners.length > 0) {
      await adminClient
        .from("signing_submissions")
        .update({ signers: updatedSigners as unknown as never })
        .eq("id", submission.id)
        .eq("tenant_id", submission.tenant_id as string);
    }

    // Actualitzar també la taula normalitzada signing_submitters
    if (data.email) {
      const submitterUpdate: Record<string, unknown> = {
        status:     signerStatus,
        updated_at: new Date().toISOString(),
      };
      if (event_type === "form.completed") submitterUpdate.completed_at = data.completed_at ?? new Date().toISOString();
      if (data.opened_at) submitterUpdate.opened_at = data.opened_at;
      if (data.slug) submitterUpdate.signing_url = `${DOCUSEAL_SIGNING_BASE_URL}/s/${data.slug}`;

      await adminClient
        .from("signing_submitters")
        .update(submitterUpdate)
        .eq("submission_id", submission.id)
        .eq("email", data.email);
    }

    // Notificació seqüencial: si el signant ha completat i el mode és app_auto_sequential,
    // encuar el seguent signant (fire-and-forget)
    if (
      event_type === "form.completed" &&
      (submission as Record<string, unknown>).notification_mode === "app_auto_sequential"
    ) {
      const completedOrder = signerOrderFromExtId >= 0
        ? signerOrderFromExtId
        : currentSigners.findIndex(s => s.email === data.email);

      if (completedOrder >= 0) {
        const nextOrder = completedOrder + 1;
        // fire-and-forget: supabase-js mai llança; cal destructurar { error } explícitament
        adminClient.rpc("enqueue_signing_notification", {
          p_submission_id: submission.id,
          p_signer_order:  nextOrder,
          p_reason:        "sequential_next",
        }).then(({ error: notifErr }) => {
          if (notifErr) {
            log("warn", FEATURE, "Error enqueueing sequential notification", {
              correlationId: submission.id as string,
              extra: { order: nextOrder, error: notifErr.message },
            });
          } else {
            log("info", FEATURE, "Sequential notification enqueued", {
              correlationId: submission.id as string,
              extra: { signer_order: nextOrder },
            });
          }
        }).catch((e: Error) => {
          log("warn", FEATURE, "Network error enqueueing sequential notification", {
            correlationId: submission.id as string,
            extra: { order: nextOrder, error: e.message },
          });
        });
      }
    }
  }

  // ── 6. Descarregar i adjuntar PDF firmat (submission.completed i fallback form.completed) ──
  if (shouldProcessAsCompleted) {
    const firstDoc = data.documents?.[0];
    const signedUrl = firstDoc?.url ?? data.submission?.combined_document_url ?? null;
    if (signedUrl) {
      await attachSignedDocument(
        adminClient,
        submission.id,
        submission.tenant_id as string,
        signedUrl,
        firstDoc.name ?? `signed-document-${data.id}`,
      );
    } else {
      log("warn", FEATURE, "completed event without documents URL", {
        correlationId: submission.id as string,
      });
    }

    // Adjuntar PDF d'auditoria (best-effort, independent del PDF firmat)
    // 1. Capturar URL directa de DocuSeal (més fiable que detectar per nom de document)
    const directAuditUrl: string | null =
      data.audit_log_url ?? data.submission?.audit_log_url ?? null;

    // 2. Guardar URL immediatament al DB — fins i tot si el download falla,
    //    el frontend pot obrir el PDF via la URL externa de DocuSeal
    if (directAuditUrl) {
      await adminClient
        .from("signing_submissions")
        .update({ audit_log_url: directAuditUrl })
        .eq("id", submission.id)
        .eq("tenant_id", submission.tenant_id as string);
    }

    // 3. Descarregar i pujar a Storage (best-effort)
    if (directAuditUrl || (data.documents && data.documents.length > 0)) {
      await attachAuditDocument(
        adminClient,
        submission.id,
        submission.tenant_id as string,
        data.documents ?? [],
        directAuditUrl,
      );
    }
  }

  log("info", FEATURE, "Webhook event processed", {
    correlationId: submission.id as string,
    extra: { event_type, status_after: statusAfter ?? "(no change)" },
  });

  return jsonOk({
    received:      true,
    processed:     true,
    submission_id: submission.id,
    event:         event_type,
    status_after:  statusAfter ?? null,
  });
});

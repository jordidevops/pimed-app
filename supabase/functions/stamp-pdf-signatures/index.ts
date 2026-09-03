/*
  Edge Function: stamp-pdf-signatures
  ─────────────────────────────────────
  Incrusta les signatures digitals (imatges canvas) i un bloc d'evidències
  a l'últim full del PDF original, calcula hashes SHA256 d'integritat,
  puja el PDF estampat al DMS com a nova versió (type=signed) i encua
  la generació del PDF d'auditoria.

  Usa pdf-lib (disponible a Deno via CDN).

  Procés:
    1. Baixa PDF original de DMS (per session.document_version_id)
    2. Calcula SHA256 del PDF original (document_hash_before)
    3. pdf-lib: afegeix pàgina final amb bloc d'evidències + imatges signatures
    4. Calcula SHA256 del PDF estampat (document_hash_after)
    5. Puja PDF estampat → nova document_version (type=signed)
    6. Insereix fila a document_signatures_audit
    7. Actualitza signing_session.result_version_id + status=signed
    8. Encua job a audit_pdf_queue
    9. Retorna { result_version_id, audit_job_id }
*/

import { corsHeaders }       from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { recordNativeSignerCompleted } from "../_shared/native-signing-completion.ts";
import { kickPdfQueueWorker } from "../_shared/kick-pdf-queue.ts";
import {
  stagingPathForGroup,
  deleteStagingPdf,
} from "../_shared/native-signing-staging.ts";
import {
  type SigningFieldArea,
  fieldsForSigner,
  detectFieldForRole,
  parseNativeEvidenceMode,
  markerTokenForRole,
} from "../_shared/signing-field-map.ts";
import { PDFDocument, rgb, StandardFonts } from "npm:pdf-lib@1.17.1";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "stamp-pdf-signatures";

const DOCUMENTS_BUCKET = "documents";
const SUPABASE_URL       = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface StampInput {
  session_id:                  string;
  operator_signature_base64?:  string | null;
  client_signature_base64:     string;
  ip_address?:                 string | null;
  user_agent?:                 string | null;
  geolocation?:                { lat: number; lon: number } | null;
}

/** pdf-lib StandardFonts només suporta WinAnsi — normalitza text per evitar crashes. */
function pdfText(value: string | null | undefined): string {
  if (!value) return "";
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^\x20-\x7E]/g, "?");
}

// ---------------------------------------------------------------------------
// SHA256 helper
// ---------------------------------------------------------------------------

async function sha256Hex(data: Uint8Array): Promise<string> {
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

// ---------------------------------------------------------------------------
// Descodificació base64 → Uint8Array
// ---------------------------------------------------------------------------

function base64ToUint8Array(b64: string): Uint8Array {
  const raw  = atob(b64.replace(/^data:[^;]+;base64,/, ""));
  const arr  = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
  return arr;
}

// ---------------------------------------------------------------------------
// Construcció del bloc d'evidències (pàgina final)
// ---------------------------------------------------------------------------

interface EvidenceBlockData {
  sessionId:    string;
  signerName:   string;
  signerEmail:  string | null;
  signerRole:   string | null;
  signedAt:     string;
  ipAddress:    string | null;
  userAgent:    string | null;
  geolocation:  { lat: number; lon: number; accuracy?: number } | null;
  hashBefore:   string;
  hashAfter:    string;
}

async function addSignaturePage(
  pdfDoc: PDFDocument,
  evidences: EvidenceBlockData,
  clientSigBytes: Uint8Array,
  operatorSigBytes: Uint8Array | null,
): Promise<void> {
  const font      = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const fontBold  = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

  const page   = pdfDoc.addPage([595.28, 841.89]); // A4
  const { width, height } = page.getSize();
  const margin = 50;
  let y = height - margin;

  // Capçalera
  page.drawText("FIRMA DIGITAL - EVIDENCIES", {
    x: margin, y,
    font: fontBold, size: 14,
    color: rgb(0.1, 0.1, 0.1),
  });
  y -= 30;

  // Línia separadora
  page.drawLine({ start: { x: margin, y }, end: { x: width - margin, y }, thickness: 1, color: rgb(0.7, 0.7, 0.7) });
  y -= 20;

  const row = (label: string, value: string) => {
    const safeValue = pdfText(value) || "-";
    page.drawText(pdfText(label), { x: margin, y, font: fontBold, size: 9, color: rgb(0.3, 0.3, 0.3) });
    page.drawText(safeValue, { x: margin + 120, y, font, size: 9, color: rgb(0.1, 0.1, 0.1) });
    y -= 16;
  };

  row("Sessio ID:",  evidences.sessionId.slice(0, 36));
  row("Signant:",    evidences.signerName || "-");
  if (evidences.signerEmail) row("Email:",     evidences.signerEmail);
  if (evidences.signerRole)  row("Rol:",       evidences.signerRole);
  row("Data i hora:", pdfText(
    new Date(evidences.signedAt).toLocaleString("ca-ES", { timeZone: "Europe/Madrid" }) + " (hora local)",
  ));
  if (evidences.ipAddress) {
    // Anonimitzar últim octet de IPv4
    const anonIp = evidences.ipAddress.replace(/(\d+)$/, "x");
    row("IP (parcial):", anonIp);
  }
  if (evidences.geolocation) {
    row("Geolocalització:", `${evidences.geolocation.lat.toFixed(4)}, ${evidences.geolocation.lon.toFixed(4)}`);
  }
  if (evidences.userAgent) {
    const ua = evidences.userAgent.length > 100
      ? evidences.userAgent.slice(0, 97) + "..."
      : evidences.userAgent;
    row("User-Agent:", ua);
  }

  y -= 10;
  page.drawLine({ start: { x: margin, y }, end: { x: width - margin, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 20;

  // Hash del document original (abans d'afegir aquesta pàgina)
  page.drawText("Hash SHA256 - Document original:", { x: margin, y, font: fontBold, size: 8, color: rgb(0.4, 0.4, 0.4) });
  y -= 14;
  page.drawText(evidences.hashBefore, { x: margin, y, font, size: 7, color: rgb(0.3, 0.3, 0.3) });
  y -= 20;
  if (evidences.hashAfter) {
    page.drawText("Hash SHA256 - Document signat:", { x: margin, y, font: fontBold, size: 8, color: rgb(0.4, 0.4, 0.4) });
    y -= 14;
    page.drawText(evidences.hashAfter, { x: margin, y, font, size: 7, color: rgb(0.3, 0.3, 0.3) });
    y -= 20;
  }

  y -= 30;
  page.drawLine({ start: { x: margin, y }, end: { x: width - margin, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 20;

  // Imatges de signatura
  const sigAreaWidth  = (width - 2 * margin - 20) / 2;
  const sigAreaHeight = 80;

  // Signatura del client
  try {
    const clientEmbed = await pdfDoc.embedPng(clientSigBytes);
    const dims = clientEmbed.scaleToFit(sigAreaWidth - 10, sigAreaHeight - 10);
    const sigX = margin + (sigAreaWidth - dims.width) / 2;
    const sigY = y - sigAreaHeight + (sigAreaHeight - dims.height) / 2;
    page.drawImage(clientEmbed, { x: sigX, y: sigY, width: dims.width, height: dims.height });
  } catch { /* si la imatge no es pot incrustar, es deixa espai buit */ }

  // Metadades sota la signatura del client
  const centerX = margin + sigAreaWidth / 2;
  let labelY = y - sigAreaHeight - 12;
  const drawCentered = (text: string, size: number, useBold = false) => {
    const safe = pdfText(text);
    if (!safe) return;
    const f = useBold ? fontBold : font;
    const tw = f.widthOfTextAtSize(safe, size);
    page.drawText(safe, {
      x: centerX - tw / 2, y: labelY, font: f, size,
      color: rgb(useBold ? 0.2 : 0.45, useBold ? 0.2 : 0.45, useBold ? 0.2 : 0.45),
    });
    labelY -= size + 3;
  };

  drawCentered(evidences.signerName || "Signant", 8, true);
  if (evidences.signerEmail) drawCentered(evidences.signerEmail, 7);
  if (evidences.signerRole)  drawCentered(evidences.signerRole, 7);

  // Signatura de l'operari (si existeix)
  if (operatorSigBytes) {
    const opX = margin + sigAreaWidth + 20;
    try {
      const opEmbed = await pdfDoc.embedPng(operatorSigBytes);
      const dims = opEmbed.scaleToFit(sigAreaWidth - 10, sigAreaHeight - 10);
      const sigX = opX + (sigAreaWidth - dims.width) / 2;
      const sigY = y - sigAreaHeight + (sigAreaHeight - dims.height) / 2;
      page.drawImage(opEmbed, { x: sigX, y: sigY, width: dims.width, height: dims.height });
    } catch { /* skip */ }
    page.drawText("Operari", {
      x: opX + sigAreaWidth / 2 - 20, y: y - sigAreaHeight - 12,
      font: fontBold, size: 8, color: rgb(0.2, 0.2, 0.2),
    });
  }

  y -= sigAreaHeight + 40;

  // Peu de pàgina legal
  page.drawText(
    pdfText("Signatura electronica simple en el sentit del Reglament eIDAS (UE) 910/2014."),
    { x: margin, y, font, size: 7, color: rgb(0.5, 0.5, 0.5) },
  );
  y -= 10;
  page.drawText(
    `Document generat automàticament. Sessió: ${evidences.sessionId}`,
    { x: margin, y, font, size: 7, color: rgb(0.6, 0.6, 0.6) },
  );
}

// ---------------------------------------------------------------------------
// Overlay de signatures a camps de plantilla (mode detached / both)
// ---------------------------------------------------------------------------

async function overlaySignatureFields(
  pdfDoc: PDFDocument,
  fields: SigningFieldArea[],
  clientSigBytes: Uint8Array,
  signerRole: string | null,
): Promise<void> {
  if (fields.length === 0) return;

  const clientEmbed = await pdfDoc.embedPng(clientSigBytes);
  const pages = pdfDoc.getPages();
  const token = signerRole ? markerTokenForRole(signerRole) : null;

  for (const field of fields) {
    const pageIndex = Math.min(Math.max(field.page - 1, 0), pages.length - 1);
    const page = pages[pageIndex];
    const { width, height } = page.getSize();
    const boxW = field.w * width;
    const boxH = field.h * height;
    const x = field.x * width;
    const y = field.y * height;

    // Tapar la caixa de signatura (placeholder + token)
    page.drawRectangle({
      x: x - 1,
      y: y - 1,
      width: boxW + 2,
      height: boxH + 2,
      color: rgb(1, 1, 1),
      borderWidth: 0,
    });

    const dims = clientEmbed.scaleToFit(boxW - 4, boxH - 4);
    page.drawImage(clientEmbed, {
      x: x + 2,
      y: y + 2,
      width: dims.width,
      height: dims.height,
    });
  }

  if (token) {
    log("debug", FEATURE, "overlay field token", {
      extra: { signer_role: signerRole, fields: fields.length, token },
    });
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
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const db = createAdminClient();
  let tenantId: string | null = null;

  let body: StampInput;
  try {
    body = await req.json() as StampInput;
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!body.session_id || !body.client_signature_base64) {
    return new Response(JSON.stringify({ error: "missing_required_fields" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    // ── 1. Llegir sessió ───────────────────────────────────────────────────────
    const { data: session, error: sessErr } = await db
      .from("document_signing_sessions")
      .select("*")
      .eq("id", body.session_id)
      .maybeSingle();

    if (sessErr || !session) {
      return new Response(JSON.stringify({ error: "session_not_found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (session.status === "signed") {
      return new Response(JSON.stringify({ error: "already_signed" }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (session.status === "cancelled") {
      return new Response(JSON.stringify({ error: "session_declined" }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    tenantId = session.tenant_id as string;

    // ── 2. Resoldre versió PDF signable ────────────────────────────────────────
    // sign_native des de plantilla crea el PDF de forma asíncrona; la sessió pot
    // tenir un ID incorrecte (p.ex. template_locale_id) fins que el job completi.
    type VersionRow = { file_path_or_url: string; document_id: string };

    async function loadVersionRow(id: string | null | undefined): Promise<VersionRow | null> {
      if (!id) return null;
      const { data, error } = await db
        .from("document_versions")
        .select("file_path_or_url, document_id")
        .eq("id", id)
        .maybeSingle();
      if (error || !data?.file_path_or_url) return null;
      return data as VersionRow;
    }

    let verRow = await loadVersionRow(session.document_version_id as string | null);
    const baseVersionId = session.document_version_id as string | null;

    const signerOrder = (session.signer_order as number | null) ?? 0;
    const signingGroupId = session.signing_group_id as string | null;
    const totalSigners = (session.total_signers as number | null) ?? 1;
    const useStaging = signingGroupId != null && totalSigners > 1;

    let stagingPath: string | null = null;
    if (useStaging) {
      stagingPath = stagingPathForGroup(tenantId, signingGroupId);
      const { data: stagingBlob, error: stagingErr } = await db.storage
        .from(DOCUMENTS_BUCKET)
        .download(stagingPath);

      if (!stagingErr && stagingBlob) {
        const baseRow = verRow ?? await loadVersionRow(baseVersionId);
        verRow = {
          file_path_or_url: stagingPath,
          document_id: baseRow?.document_id ?? "",
        };
      }
    }

    if (!verRow && session.pdf_job_id) {
      const { data: jobRow, error: jobErr } = await db
        .from("document_pdf_jobs")
        .select("result_version_id, status")
        .eq("id", session.pdf_job_id as string)
        .maybeSingle();

      if (jobErr || !jobRow) {
        return new Response(JSON.stringify({ error: "pdf_job_not_found" }), {
          status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (jobRow.status !== "completed" || !jobRow.result_version_id) {
        return new Response(JSON.stringify({ error: "pdf_job_not_ready" }), {
          status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const jobVersionId = jobRow.result_version_id as string;
      verRow = await loadVersionRow(jobVersionId);
    }

    if (!verRow) {
      return new Response(JSON.stringify({ error: "document_version_not_found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const origPath = verRow.file_path_or_url as string;

    // ── 3. Baixar PDF original ─────────────────────────────────────────────────
    const { data: origBlob, error: downErr } = await db.storage
      .from(DOCUMENTS_BUCKET)
      .download(origPath);

    if (downErr || !origBlob) {
      return new Response(JSON.stringify({ error: "download_failed", detail: downErr?.message }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const origBytes = new Uint8Array(await origBlob.arrayBuffer());

    // ── 4. Config mode evidències ──────────────────────────────────────────────
    const { data: cfgRaw } = await db.rpc("get_pdf_converter_config");
    const evidenceMode = parseNativeEvidenceMode((cfgRaw ?? {}) as Record<string, unknown>);
    const doOverlay    = evidenceMode === "detached" || evidenceMode === "both";
    const doEmbedPage  = evidenceMode === "embedded" || evidenceMode === "both";

    // ── 5. SHA256 del PDF original ─────────────────────────────────────────────
    const hashBefore = await sha256Hex(origBytes);

    // ── 6. Estampar segons mode (overlay a etiquetes i/o pàgina evidències) ────
    const pdfDoc = await PDFDocument.load(origBytes, { ignoreEncryption: true });

    const evidenceData: EvidenceBlockData = {
      sessionId:   body.session_id,
      signerName:  pdfText(session.signer_name as string) || "",
      signerEmail: session.signer_email as string | null,
      signerRole:  session.signer_role as string | null,
      signedAt:    new Date().toISOString(),
      ipAddress:   body.ip_address ?? null,
      userAgent:   body.user_agent ?? null,
      geolocation: body.geolocation ?? null,
      hashBefore,
      hashAfter:   "",
    };

    const clientSigBytes   = base64ToUint8Array(body.client_signature_base64);
    const operatorSigBytes = body.operator_signature_base64
      ? base64ToUint8Array(body.operator_signature_base64)
      : null;

    const fieldMap = session.signing_field_map as SigningFieldArea[] | null;
    const signerRole = session.signer_role as string | null;
    let signerFields = fieldsForSigner(
      fieldMap,
      signerRole,
      signerOrder,
      pdfDoc.getPageCount(),
      [],
    );

    if (doOverlay && signerRole) {
      const liveField = await detectFieldForRole(origBytes, signerRole);
      if (liveField) {
        signerFields = [liveField];
      }
    }

    if (doOverlay) {
      await overlaySignatureFields(pdfDoc, signerFields, clientSigBytes, signerRole);
    }

    if (doEmbedPage) {
      await addSignaturePage(pdfDoc, evidenceData, clientSigBytes, operatorSigBytes);
    }

    const stampedBytes = await pdfDoc.save();

    // ── 7. SHA256 del PDF estampat ─────────────────────────────────────────────
    const hashAfter = await sha256Hex(new Uint8Array(stampedBytes));

    // ── 7. Pujar imatge de signatura al Storage ────────────────────────────────
    const sigImagePath = `${tenantId}/signatures/${crypto.randomUUID()}.png`;
    const { error: sigUpErr } = await db.storage
      .from(DOCUMENTS_BUCKET)
      .upload(sigImagePath, new Blob([clientSigBytes], { type: "image/png" }), {
        contentType: "image/png", upsert: false,
      });
    if (sigUpErr) log("warn", FEATURE, "Sig image upload error", { tenantId, correlationId: body.session_id, extra: { error: sigUpErr.message } });

    const documentId = (verRow.document_id as string) || null;

    // ── 8. Pujar PDF estampat / staging ─────────────────────────────────────────
    let docTitle = "document";
    if (verRow.document_id) {
      const { data: docRow } = await db
        .from("documents")
        .select("title")
        .eq("id", verRow.document_id)
        .maybeSingle();
      docTitle = (docRow?.title as string | undefined) ?? docTitle;
    }
    const stampedName = `${docTitle.replace(/[^\w.-]/g, "_")}_signed.pdf`;
    let stampedPath: string;
    let resultVersionId: string | null = null;
    const isLastSigner = signerOrder >= totalSigners - 1;
    const allSignedAfter = useStaging ? isLastSigner : true;

    if (useStaging && !allSignedAfter) {
      stampedPath = stagingPath!;
      const { error: upErr } = await db.storage
        .from(DOCUMENTS_BUCKET)
        .upload(stampedPath, new Blob([stampedBytes], { type: "application/pdf" }), {
          contentType: "application/pdf", upsert: true,
        });
      if (upErr) throw new Error(`Staging PDF upload error: ${upErr.message}`);
    } else if (useStaging && allSignedAfter) {
      stampedPath = stagingPath!;
      const { error: upErr } = await db.storage
        .from(DOCUMENTS_BUCKET)
        .upload(stampedPath, new Blob([stampedBytes], { type: "application/pdf" }), {
          contentType: "application/pdf", upsert: true,
        });
      if (upErr) throw new Error(`Staging PDF upload error: ${upErr.message}`);

      if (documentId) {
        const { data: verRes, error: verResErr } = await db.rpc("add_document_version_internal", {
          p_document_id:      documentId,
          p_file_path_or_url: stampedPath,
          p_mime_type:        "application/pdf",
          p_size_bytes:       stampedBytes.byteLength,
          p_storage_type:     "native",
        });
        if (verResErr) throw new Error(`add_document_version error: ${verResErr.message}`);
        const parsed = typeof verRes === "string" ? JSON.parse(verRes) : verRes as Record<string, unknown>;
        resultVersionId = (parsed?.version?.id ?? parsed?.id ?? null) as string | null;
      }
    } else {
      stampedPath = `${tenantId}/${crypto.randomUUID()}/${stampedName}`;
      const { error: upErr } = await db.storage
        .from(DOCUMENTS_BUCKET)
        .upload(stampedPath, new Blob([stampedBytes], { type: "application/pdf" }), {
          contentType: "application/pdf", upsert: false,
        });
      if (upErr) throw new Error(`Stamped PDF upload error: ${upErr.message}`);

      if (documentId) {
        const { data: verRes, error: verResErr } = await db.rpc("add_document_version_internal", {
          p_document_id:      documentId,
          p_file_path_or_url: stampedPath,
          p_mime_type:        "application/pdf",
          p_size_bytes:       stampedBytes.byteLength,
          p_storage_type:     "native",
        });
        if (verResErr) throw new Error(`add_document_version error: ${verResErr.message}`);
        const parsed = typeof verRes === "string" ? JSON.parse(verRes) : verRes as Record<string, unknown>;
        resultVersionId = (parsed?.version?.id ?? parsed?.id ?? null) as string | null;
      }
    }

    // ── 11. Inserir audit record ────────────────────────────────────────────────
    const now = new Date().toISOString();
    if (documentId) {
      await db.rpc("insert_signature_audit_service", {
        p_tenant_id:            tenantId,
        p_document_id:          documentId,
        p_session_id:           body.session_id,
        p_signer_name:          session.signer_name,
        p_signer_email:         session.signer_email,
        p_signer_role:          session.signer_role,
        p_timestamp_signed:     now,
        p_ip_address:           evidenceData.ipAddress,
        p_user_agent:           evidenceData.userAgent,
        p_geolocation:          evidenceData.geolocation,
        p_signature_image_path: sigImagePath,
        p_document_hash_before: hashBefore,
        p_document_hash_after:  hashAfter,
      });
    }

    // ── 12. Actualitzar sessió com a signed (via RPC → data.*) ─────────────────
    await db.rpc("finalize_signing_session", {
      p_session_id:           body.session_id,
      p_result_version_id:    resultVersionId,
      p_signature_image_path: sigImagePath,
      p_ip_address:           evidenceData.ipAddress,
      p_user_agent:           evidenceData.userAgent,
      p_geolocation:          evidenceData.geolocation,
      p_signed_at:            now,
    });

    // ── 12b. Submission Hub: actualitzar signing_submissions ───────────────────
    const hubResult = await recordNativeSignerCompleted(
      db,
      body.session_id,
      allSignedAfter ? resultVersionId : null,
      useStaging ? stampedPath : null,
    );
    if (hubResult.submission_id) {
      log("info", FEATURE, "Submission hub status updated", {
        extra: {
          submission_id: hubResult.submission_id,
          status: hubResult.status,
          all_signed: hubResult.all_signed,
        },
      });
    }

    // ── 13. Encuar job d'auditoria PDF (async) ────────────────────────────────
    let auditJobId: string | null = null;
    if (hubResult.all_signed && signingGroupId && hubResult.submission_id) {
      try {
        const { data: auditJobData } = await db.rpc("create_pdf_job", {
          p_tenant_id:       tenantId,
          p_source_type:     "document_existing",
          p_source_ref_id:   resultVersionId,
          p_template_type:   "html",
          p_document_title:  `Registre d'auditoria — ${docTitle}`,
          p_output_profile:  "pdfa3b",
          p_idempotency_key: `audit-group-${signingGroupId}`,
          p_metadata:        {
            type:              "audit_certificate",
            signing_group_id:  signingGroupId,
            submission_id:     hubResult.submission_id,
          },
        });
        const auditJob = auditJobData as { job_id: string } | null;
        auditJobId = auditJob?.job_id ?? null;
        if (auditJobId) kickPdfQueueWorker(SUPABASE_URL, SERVICE_ROLE_KEY);
      } catch (auditErr) {
        log("warn", FEATURE, "Could not enqueue group audit PDF job", {
          tenantId,
          correlationId: body.session_id,
          extra: { error: (auditErr as Error).message },
        });
      }
    }

    log("info", FEATURE, "Session signed", {
      tenantId,
      correlationId: body.session_id,
      extra: { resultVersionId },
    });

    return new Response(JSON.stringify({
      success:           true,
      result_version_id: resultVersionId,
      audit_job_id:      auditJobId,
      document_hash_before: hashBefore,
      document_hash_after:  hashAfter,
    }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    const errMsg = (err as Error).message;
    log("error", FEATURE, "Stamp error", {
      tenantId: tenantId ?? undefined,
      correlationId: body.session_id,
      extra: { error: errMsg },
    });

    if (tenantId) {
      const operationLog = createOperationLogService(db);
      await operationLog.log({
        tenantId,
        integrationType: "signing",
        operationCode: "stamp_pdf",
        status: "failed",
        title: "Error estampant signatures al PDF",
        message: errMsg.slice(0, 200),
        errorCode: "stamp_failed",
        errorMessage: errMsg,
        correlationId: body.session_id,
        entityType: "signing_session",
        entityId: body.session_id,
        isRetryable: false,
      });
    }

    if (isInfrastructureBug(err)) {
      captureException(err, {
        feature: FEATURE,
        tenantId: tenantId ?? undefined,
        correlationId: body.session_id,
      });
    }

    return new Response(JSON.stringify({ error: errMsg }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

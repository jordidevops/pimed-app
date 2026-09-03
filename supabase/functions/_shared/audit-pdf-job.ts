/**
 * Generació del PDF d'auditoria (registre de signatura native).
 * Un sol certificat per submission/grup quan tots els signants han completat.
 * NO es crea com a versió del document — només es guarda a Storage i
 * signing_submissions.audit_trail_storage_path (com DocuSeal).
 */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { createGotenbergClientFromConfig } from "./gotenberg-client.ts";
import { roleDisplayLabel } from "./signing-field-map.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "audit-pdf-job";

export interface AuditSignerBlock {
  sessionId:         string;
  signerName:        string;
  signerEmail:       string | null;
  signerRole:        string | null;
  signerOrder:       number;
  signedAt:          string;
  ipAddress:         string | null;
  userAgent:         string | null;
  geolocation:       { lat: number; lon: number } | null;
  hashBefore:        string;
  hashAfter:         string;
  signatureImageUrl: string | null;
  events:            Array<{ event_type: string; created_at: string }>;
}

export function buildGroupAuditHtml(data: {
  documentTitle:    string;
  submissionId?:    string;
  signingGroupId?:  string;
  signedDocumentHash: string | null;
  signers:          AuditSignerBlock[];
}): string {
  const formatDate = (iso: string) =>
    new Date(iso).toLocaleString("ca-ES", {
      timeZone: "Europe/Madrid",
      dateStyle: "long",
      timeStyle: "medium",
    });

  const signersHtml = data.signers.map((s, idx) => {
    const roleLabel = s.signerRole ? roleDisplayLabel(s.signerRole, s.signerName) : s.signerName;
    const eventsHtml = s.events.map(e => `
      <tr>
        <td>${formatDate(e.created_at)}</td>
        <td>${e.event_type.replace(/_/g, " ")}</td>
      </tr>
    `).join("");

    return `
    <section class="signer-block">
      <h2>Signant ${idx + 1} — ${roleLabel}</h2>
      <table>
        <tr><th>Nom</th><td>${s.signerName || "—"}</td></tr>
        ${s.signerEmail ? `<tr><th>Email</th><td>${s.signerEmail}</td></tr>` : ""}
        ${s.signerRole  ? `<tr><th>Rol</th><td>${roleLabel}</td></tr>` : ""}
        <tr><th>Data de signatura</th><td>${formatDate(s.signedAt)}</td></tr>
        ${s.ipAddress   ? `<tr><th>IP (parcial)</th><td>${s.ipAddress.replace(/(\d+)$/, "x")}</td></tr>` : ""}
        ${s.userAgent   ? `<tr><th>Navegador</th><td style="font-size:8pt;word-break:break-all;">${s.userAgent.slice(0, 200)}</td></tr>` : ""}
        ${s.geolocation ? `<tr><th>Geolocalització</th><td>${s.geolocation.lat.toFixed(4)}, ${s.geolocation.lon.toFixed(4)}</td></tr>` : ""}
      </table>
      ${s.signatureImageUrl
        ? `<p class="sig-label">Signatura manuscrita digital:</p><img class="sig-img" src="${s.signatureImageUrl}" alt="Signatura" />`
        : ""}
      <h3>Prova d'integritat (aquest signant)</h3>
      <table>
        <tr><th>SHA256 — Abans</th><td class="hash">${s.hashBefore || "—"}</td></tr>
        <tr><th>SHA256 — Després</th><td class="hash">${s.hashAfter || "—"}</td></tr>
      </table>
      <h3>Registre d'events</h3>
      <table>
        <tr><th>Data i hora</th><th>Event</th></tr>
        ${eventsHtml || "<tr><td colspan=\"2\">—</td></tr>"}
      </table>
    </section>`;
  }).join("");

  return `<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="UTF-8">
  <title>Registre d'Auditoria — ${data.documentTitle}</title>
  <style>
    body { font-family: Arial, sans-serif; font-size: 10pt; line-height: 1.5; margin: 2cm; color: #111; }
    h1 { font-size: 16pt; margin-bottom: 0.3em; }
    h2 { font-size: 12pt; color: #333; border-bottom: 1px solid #ccc; padding-bottom: 4px; margin-top: 1.5em; }
    h3 { font-size: 10pt; color: #444; margin-top: 1em; margin-bottom: 0.3em; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 0.8em; }
    th, td { border: 1px solid #ccc; padding: 5px 10px; text-align: left; vertical-align: top; }
    th { background: #f5f5f5; font-weight: bold; width: 160px; }
    .hash { font-family: monospace; font-size: 7pt; word-break: break-all; }
    .footer { margin-top: 3em; font-size: 8pt; color: #666; border-top: 1px solid #ddd; padding-top: 0.5em; }
    .sig-img { max-width: 220px; max-height: 90px; border: 1px solid #ddd; padding: 4px; display: block; margin: 6px 0 12px; }
    .sig-label { font-size: 9pt; color: #555; margin: 8px 0 4px; }
    .badge { display: inline-block; background: #e8f5e9; color: #2e7d32; border: 1px solid #a5d6a7;
             padding: 4px 10px; border-radius: 4px; font-weight: bold; font-size: 11pt; }
    .signer-block { page-break-inside: avoid; margin-bottom: 1.5em; }
  </style>
</head>
<body>
  <h1>Registre d'Auditoria de Signatura Digital</h1>
  <p class="badge">✓ Document signat electrònicament</p>
  <h2>Document</h2>
  <table>
    <tr><th>Títol</th><td>${data.documentTitle}</td></tr>
    <tr><th>Signants</th><td>${data.signers.length}</td></tr>
    ${data.submissionId ? `<tr><th>Submission ID</th><td class="hash">${data.submissionId}</td></tr>` : ""}
    ${data.signedDocumentHash ? `<tr><th>SHA256 — Document final signat</th><td class="hash">${data.signedDocumentHash}</td></tr>` : ""}
  </table>
  ${signersHtml}
  <div class="footer">
    <p>Signatura electrònica simple d'acord amb el Reglament (UE) 910/2014 (eIDAS), article 3.10.</p>
    <p>Certificat generat automàticament. Aquest document és el registre d'auditoria; el document signat és un fitxer separat.</p>
    ${data.signingGroupId ? `<p>Grup de signatura: ${data.signingGroupId}</p>` : ""}
  </div>
</body>
</html>`;
}

/** @deprecated Usar buildGroupAuditHtml */
export function buildAuditHtml(data: {
  sessionId:    string;
  documentTitle: string;
  signerName:   string;
  signerEmail:  string | null;
  signerRole:   string | null;
  signedAt:     string;
  ipAddress:    string | null;
  userAgent:    string | null;
  geolocation:  { lat: number; lon: number } | null;
  hashBefore:   string;
  hashAfter:    string;
  events:       Array<{ event_type: string; created_at: string }>;
  signatureImageUrl: string | null;
}): string {
  return buildGroupAuditHtml({
    documentTitle:      data.documentTitle,
    signedDocumentHash: data.hashAfter || null,
    signers: [{
      sessionId:         data.sessionId,
      signerName:        data.signerName,
      signerEmail:       data.signerEmail,
      signerRole:        data.signerRole,
      signerOrder:       0,
      signedAt:          data.signedAt,
      ipAddress:         data.ipAddress,
      userAgent:         data.userAgent,
      geolocation:       data.geolocation,
      hashBefore:        data.hashBefore,
      hashAfter:         data.hashAfter,
      signatureImageUrl: data.signatureImageUrl,
      events:            data.events,
    }],
  });
}

async function signedUrlForPath(
  db: SupabaseClient,
  path: string | null | undefined,
): Promise<string | null> {
  if (!path) return null;
  const { data } = await db.storage.from("documents").createSignedUrl(path, 300);
  return data?.signedUrl ?? null;
}

/** Processa un job document_pdf_jobs amb metadata.type = audit_certificate. */
export async function processAuditCertificateJob(
  db: SupabaseClient,
  job: Record<string, unknown>,
  opts: { jobId: string; tenantId: string; workerId: string },
): Promise<void> {
  const meta = (job.metadata ?? {}) as Record<string, unknown>;
  const signingGroupId = meta.signing_group_id as string | undefined;
  const submissionId   = meta.submission_id as string | undefined;
  const legacySessionId = meta.session_id as string | undefined;

  if (!signingGroupId && !legacySessionId) {
    throw new Error("audit_certificate job missing signing_group_id");
  }

  const now = new Date().toISOString();

  await db.from("document_pdf_jobs").update({
    status: "processing", locked_at: now, locked_by: opts.workerId,
    attempt_count: ((job.attempt_count as number) ?? 0) + 1, updated_at: now,
  }).eq("id", opts.jobId);

  let groupId = signingGroupId ?? null;
  if (!groupId && legacySessionId) {
    const { data: legacySess } = await db
      .from("document_signing_sessions")
      .select("signing_group_id")
      .eq("id", legacySessionId)
      .maybeSingle();
    groupId = legacySess?.signing_group_id as string | null;
  }
  if (!groupId) throw new Error("signing_group_id not found for audit job");

  const { data: sessions = [] } = await db
    .from("document_signing_sessions")
    .select("*")
    .eq("signing_group_id", groupId)
    .eq("status", "signed")
    .order("signer_order", { ascending: true });

  if (!sessions.length) {
    throw new Error(`No signed sessions in group ${groupId}`);
  }

  const sessionIds = sessions.map((s) => s.id as string);

  const { data: auditRecords = [] } = await db
    .from("document_signatures_audit")
    .select("*")
    .in("session_id", sessionIds);

  const auditBySession = new Map(
    (auditRecords ?? []).map((r) => [r.session_id as string, r]),
  );

  const signerBlocks: AuditSignerBlock[] = [];

  for (const session of sessions) {
    const sid = session.id as string;
    const auditRecord = auditBySession.get(sid);

    const { data: evidences = [] } = await db
      .from("document_signature_evidences")
      .select("event_type, created_at")
      .eq("session_id", sid)
      .order("created_at", { ascending: true });

    const signatureImageUrl = await signedUrlForPath(
      db,
      auditRecord?.signature_image_path as string | undefined,
    );

    const timestamps = (session.timestamps ?? {}) as Record<string, string>;

    signerBlocks.push({
      sessionId:         sid,
      signerName:        session.signer_name as string ?? "",
      signerEmail:       session.signer_email as string | null,
      signerRole:        session.signer_role as string | null,
      signerOrder:       (session.signer_order as number) ?? 0,
      signedAt:          timestamps.signed_at ?? now,
      ipAddress:         session.ip_address as string | null,
      userAgent:         session.user_agent as string | null,
      geolocation:       session.geolocation as { lat: number; lon: number } | null,
      hashBefore:        auditRecord?.document_hash_before as string ?? "",
      hashAfter:         auditRecord?.document_hash_after as string ?? "",
      signatureImageUrl,
      events:            (evidences ?? []) as Array<{ event_type: string; created_at: string }>,
    });
  }

  const lastSession = sessions[sessions.length - 1];
  const finalHash = auditBySession.get(lastSession.id as string)?.document_hash_after as string | null;

  let documentId: string | null = null;
  const resultVersionId = lastSession.result_version_id as string | null;
  if (resultVersionId) {
    const { data: verMeta } = await db
      .from("document_versions")
      .select("document_id")
      .eq("id", resultVersionId)
      .maybeSingle();
    documentId = verMeta?.document_id as string | null;
  }

  let docTitle = (job.document_title as string) ?? "Document";
  if (documentId) {
    const { data: docData } = await db
      .from("documents")
      .select("title")
      .eq("id", documentId)
      .maybeSingle();
    if (docData?.title) docTitle = docData.title as string;
  }

  const htmlContent = buildGroupAuditHtml({
    documentTitle:      docTitle,
    submissionId:       submissionId ?? undefined,
    signingGroupId:     groupId,
    signedDocumentHash: finalHash ?? null,
    signers:            signerBlocks,
  });

  const { data: cfg } = await db.rpc("get_pdf_converter_config");
  const config = (cfg ?? {}) as Record<string, unknown>;
  const gotClient = createGotenbergClientFromConfig(config);
  const pdfBytes  = await gotClient.htmlToPdf(htmlContent, { profile: "pdfa3b" });

  const auditPath = `${opts.tenantId}/audit/${crypto.randomUUID()}/audit_registre.pdf`;
  const { error: upErr } = await db.storage.from("documents").upload(
    auditPath, new Blob([pdfBytes], { type: "application/pdf" }),
    { contentType: "application/pdf", upsert: false },
  );
  if (upErr) throw new Error(`Audit PDF upload error: ${upErr.message}`);

  // NO crear document_version — l'auditoria és un artefacte separat (com DocuSeal)
  for (const sid of sessionIds) {
    await db.from("document_signatures_audit").update({
      audit_pdf_path: auditPath,
    }).eq("session_id", sid);
  }

  const auditUpdate = {
    audit_trail_storage_path: auditPath,
    updated_at:               new Date().toISOString(),
  };

  if (submissionId) {
    const { error: byIdErr } = await db
      .from("signing_submissions")
      .update(auditUpdate)
      .eq("id", submissionId);
    if (byIdErr) {
      log("warn", FEATURE, "Failed to update submission audit path by submission_id", {
        correlationId: submissionId ?? undefined,
        extra: { error: byIdErr.message },
      });
    }
  }

  const { error: byGroupErr } = await db
    .from("signing_submissions")
    .update(auditUpdate)
    .eq("native_group_id", groupId)
    .eq("signing_provider", "native");

  if (byGroupErr) {
    log("warn", FEATURE, "Failed to update submission audit path by native_group_id", {
      extra: { group_id: groupId, error: byGroupErr.message },
    });
  }

  await db.from("document_pdf_jobs").update({
    status:              "completed",
    result_version_id:     null,
    size_output_bytes:     pdfBytes.byteLength,
    locked_at:             null,
    locked_by:             null,
    completed_at:          new Date().toISOString(),
    updated_at:            new Date().toISOString(),
    metadata:              { ...meta, audit_storage_path: auditPath },
  }).eq("id", opts.jobId);

  await db.from("document_pdf_events").insert({
    job_id: opts.jobId,
    event_type: "completed",
    payload: { audit_storage_path: auditPath, type: "audit_certificate", signing_group_id: groupId },
  });

  log("info", FEATURE, "Group audit PDF completed", {
    extra: { group_id: groupId, path: auditPath, signers: signerBlocks.length },
  });
}

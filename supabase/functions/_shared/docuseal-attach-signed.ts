/**
 * Shared DocuSeal signed-PDF attach (webhook + reconcile job).
 * Records commercial artifact_status via RPC when available.
 */
import { createAdminClient, createAdminDataClient } from "./supabase.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "docuseal-attach-signed";
const DOCUMENTS_BUCKET = "documents";

type AdminClient = ReturnType<typeof createAdminClient>;

export type AttachSignedResult = {
  ok: boolean;
  alreadyAttached?: boolean;
  errorCode?: string;
  message?: string;
};

/** Honest attach contract: ok only with version id or alreadyAttached. */
export function finalizeAttachOk(
  versionId: string | null | undefined,
  alreadyAttached = false,
): AttachSignedResult {
  if (alreadyAttached) return { ok: true, alreadyAttached: true };
  if (!versionId) {
    return {
      ok: false,
      errorCode: "version_id_missing",
      message: "add_document_version_internal returned no id",
    };
  }
  return { ok: true };
}

function computeNeighborPath(
  tenantId: string,
  submissionId: string,
  originalPath: string | null,
): string {
  if (originalPath) {
    const segments = originalPath.split("/");
    if (segments.length >= 3) {
      const fileUuid = segments[1];
      const fileName = segments.slice(2).join("/");
      const dotIdx = fileName.lastIndexOf(".");
      const baseName = dotIdx >= 0 ? fileName.slice(0, dotIdx) : fileName;
      return `${tenantId}/${fileUuid}/${baseName}_signed.pdf`;
    }
  }
  return `${tenantId}/signed/${submissionId}_signed.pdf`;
}

async function recordArtifactStatus(
  adminClient: AdminClient,
  submissionId: string,
  status: "pending" | "attached" | "failed",
  error?: string | null,
  signedUrl?: string | null,
): Promise<void> {
  const { error: rpcErr } = await adminClient.rpc(
    "record_signing_submission_artifact_status",
    {
      p_submission_id: submissionId,
      p_status: status,
      p_error: error ?? null,
      p_signed_url: signedUrl ?? null,
    },
  );
  if (rpcErr) {
    log("warn", FEATURE, "record artifact status failed", {
      correlationId: submissionId,
      extra: { error: rpcErr.message, status },
    });
  }
}

export async function attachSignedDocumentFromUrl(params: {
  adminClient: AdminClient;
  submissionId: string;
  tenantId: string;
  documentUrl: string;
  documentName: string;
}): Promise<AttachSignedResult> {
  const { adminClient, submissionId, tenantId, documentUrl, documentName } =
    params;

  const { data: currentSubmission } = await adminClient
    .from("signing_submissions")
    .select("result_document_version_id")
    .eq("id", submissionId)
    .maybeSingle();

  if (currentSubmission?.result_document_version_id) {
    await recordArtifactStatus(adminClient, submissionId, "attached");
    return finalizeAttachOk(
      currentSubmission.result_document_version_id as string,
      true,
    );
  }

  await recordArtifactStatus(
    adminClient,
    submissionId,
    "pending",
    null,
    documentUrl,
  );

  let fileData: Uint8Array;
  try {
    const res = await fetch(documentUrl);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    fileData = new Uint8Array(await res.arrayBuffer());
  } catch (err) {
    const msg = (err as Error).message;
    await recordArtifactStatus(
      adminClient,
      submissionId,
      "failed",
      `download_failed:${msg}`,
      documentUrl,
    );
    return { ok: false, errorCode: "download_failed", message: msg };
  }

  const { data: sub, error: subErr } = await adminClient
    .from("signing_submissions")
    .select("source_document_version_id")
    .eq("id", submissionId)
    .single();

  if (subErr || !sub) {
    await recordArtifactStatus(
      adminClient,
      submissionId,
      "failed",
      "submission_not_found",
      documentUrl,
    );
    return {
      ok: false,
      errorCode: "submission_not_found",
      message: subErr?.message ?? "missing",
    };
  }

  let documentId: string | null = null;
  let originalPath: string | null = null;

  if (sub.source_document_version_id) {
    const dataClient = createAdminDataClient();
    const { data: srcVer } = await dataClient
      .from("document_versions")
      .select("document_id, file_path_or_url")
      .eq("id", sub.source_document_version_id)
      .maybeSingle();
    documentId = (srcVer?.document_id as string | undefined) ?? null;
    originalPath = (srcVer?.file_path_or_url as string | undefined) ?? null;
  }

  if (!documentId) {
    const safeName = documentName.replace(/[^\w.\-]/g, "_").slice(0, 200);
    const dataClient = createAdminDataClient();
    const { data: newDoc, error: docErr } = await dataClient
      .from("documents")
      .insert({ tenant_id: tenantId, title: `Signed - ${safeName}` })
      .select("id")
      .single();
    if (docErr || !newDoc?.id) {
      const msg = docErr?.message ?? "unknown";
      await recordArtifactStatus(
        adminClient,
        submissionId,
        "failed",
        `document_create_failed:${msg}`,
        documentUrl,
      );
      return { ok: false, errorCode: "document_create_failed", message: msg };
    }
    documentId = newDoc.id as string;
  }

  const path = computeNeighborPath(tenantId, submissionId, originalPath);
  const blob = new Blob([fileData.buffer as ArrayBuffer], {
    type: "application/pdf",
  });

  const { error: uploadErr } = await adminClient.storage
    .from(DOCUMENTS_BUCKET)
    .upload(path, blob, { contentType: "application/pdf", upsert: false });

  if (uploadErr) {
    const msg = uploadErr.message.toLowerCase();
    if (!msg.includes("already exists") && !msg.includes("duplicate")) {
      await recordArtifactStatus(
        adminClient,
        submissionId,
        "failed",
        `upload_failed:${uploadErr.message}`,
        documentUrl,
      );
      return {
        ok: false,
        errorCode: "upload_failed",
        message: uploadErr.message,
      };
    }
  }

  // Prefer version under the same document (avoids cross-tenant path collisions).
  const { data: existingVersion } = await adminClient
    .from("document_versions")
    .select("id")
    .eq("file_path_or_url", path)
    .eq("document_id", documentId)
    .maybeSingle();

  if (existingVersion?.id) {
    await adminClient
      .from("signing_submissions")
      .update({ result_document_version_id: existingVersion.id })
      .eq("id", submissionId)
      .eq("tenant_id", tenantId);
    await recordArtifactStatus(adminClient, submissionId, "attached");
    return finalizeAttachOk(existingVersion.id as string);
  }

  const { data: verData, error: verErr } = await adminClient.rpc(
    "add_document_version_internal",
    {
      p_document_id: documentId,
      p_file_path_or_url: path,
      p_mime_type: "application/pdf",
      p_size_bytes: fileData.length,
      p_storage_type: "native",
    },
  );

  if (verErr) {
    await recordArtifactStatus(
      adminClient,
      submissionId,
      "failed",
      `version_create_failed:${verErr.message}`,
      documentUrl,
    );
    return {
      ok: false,
      errorCode: "version_create_failed",
      message: verErr.message,
    };
  }

  const parsedVer = typeof verData === "string" ? JSON.parse(verData) : verData;
  const versionId = (parsedVer as Record<string, unknown>).id as
    | string
    | undefined;

  const finalize = finalizeAttachOk(versionId);
  if (!finalize.ok) {
    await recordArtifactStatus(
      adminClient,
      submissionId,
      "failed",
      "version_id_missing",
      documentUrl,
    );
    return finalize;
  }

  await adminClient
    .from("signing_submissions")
    .update({ result_document_version_id: versionId })
    .eq("id", submissionId)
    .eq("tenant_id", tenantId);
  await recordArtifactStatus(adminClient, submissionId, "attached");

  log("info", FEATURE, "Signed PDF attached", {
    tenantId,
    correlationId: submissionId,
    extra: { document_id: documentId, version_id: versionId, path },
  });

  return finalize;
}

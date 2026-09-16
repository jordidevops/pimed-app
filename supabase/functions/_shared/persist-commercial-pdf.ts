import { createAdminClient } from "./supabase.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "persist-commercial-pdf";
const DOCUMENTS_BUCKET = "documents";

export function isCommercialPdfJob(job: Record<string, unknown>): boolean {
  const meta = (job.metadata ?? {}) as Record<string, unknown>;
  return meta.type === "commercial_document" || job.source_type === "commercial_document";
}

export function commercialJobIds(job: Record<string, unknown>): {
  commercialDocumentId: string;
  clientOpId: string;
} {
  const meta = (job.metadata ?? {}) as Record<string, unknown>;
  const commercialDocumentId = String(meta.commercial_document_id ?? job.source_ref_id ?? "");
  const clientOpId =
    typeof meta.client_op_id === "string" && meta.client_op_id.length > 0
      ? meta.client_op_id
      : crypto.randomUUID();
  return { commercialDocumentId, clientOpId };
}

export type PersistCommercialPdfResult = {
  documentId: string;
  versionId: string | null;
  path: string;
};

function parseRpcJson(data: unknown): Record<string, unknown> {
  if (typeof data === "string") {
    try {
      return JSON.parse(data) as Record<string, unknown>;
    } catch {
      return {};
    }
  }
  if (data && typeof data === "object" && !Array.isArray(data)) {
    return data as Record<string, unknown>;
  }
  return {};
}

function nodeId(node: unknown, fallbackKeys: string[]): string | null {
  if (typeof node === "string" && node.length > 0) return node;
  if (!node || typeof node !== "object") return null;
  const rec = node as Record<string, unknown>;
  for (const key of fallbackKeys) {
    const value = rec[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return null;
}

export async function persistCommercialRenderedPdf(params: {
  admin: ReturnType<typeof createAdminClient>;
  tenantId: string;
  commercialDocumentId: string;
  title: string;
  createdBy: string | null;
  clientOpId: string;
  pdfJobId?: string | null;
  pdfBytes?: Uint8Array;
  existingPath?: string;
}): Promise<PersistCommercialPdfResult> {
  let path = params.existingPath ?? "";
  if (!path) {
    if (!params.pdfBytes) {
      throw new Error("commercial_pdf_bytes_required");
    }
    const safeTitle = params.title.replace(/[^\w.-]+/g, "_") || "document";
    path = `${params.tenantId}/commercial/${params.commercialDocumentId}/${crypto.randomUUID()}/${safeTitle}.pdf`;
    const { error: uploadErr } = await params.admin.storage
      .from(DOCUMENTS_BUCKET)
      .upload(path, params.pdfBytes, {
        contentType: "application/pdf",
        upsert: false,
      });
    if (uploadErr) throw new Error(`PDF upload error: ${uploadErr.message}`);
  }

  const sizeBytes = params.pdfBytes?.byteLength ?? 0;
  const { data: rpcData, error: rpcErr } = await (params.admin as any).rpc(
    "create_commercial_rendered_document_internal",
    {
      p_tenant_id: params.tenantId,
      p_commercial_document_id: params.commercialDocumentId,
      p_title: params.title,
      p_file_path_or_url: path,
      p_mime_type: "application/pdf",
      p_size_bytes: sizeBytes,
      p_created_by: params.createdBy,
    },
  );
  if (rpcErr || !rpcData) {
    throw new Error(`create_commercial_rendered_document_internal: ${rpcErr?.message ?? "empty"}`);
  }

  const created = parseRpcJson(rpcData);
  const documentId = nodeId(created.document, ["id"]) ?? nodeId(created, ["document_id"]);
  const versionId = nodeId(created.version, ["id"]) ?? nodeId(created, ["version_id"]);
  if (!documentId) {
    throw new Error("commercial_rendered_document_id_missing");
  }

  const { error: linkErr } = await (params.admin as any).rpc("link_commercial_rendered_document", {
    p_document_id: params.commercialDocumentId,
    p_dms_document_id: documentId,
    p_client_op_id: params.clientOpId,
    p_pdf_job_id: params.pdfJobId ?? null,
  });
  if (linkErr) {
    log("warn", FEATURE, "link_commercial_rendered_document failed", {
      tenantId: params.tenantId,
      extra: { error: linkErr.message, commercial_document_id: params.commercialDocumentId },
    });
    throw new Error(`link_commercial_rendered_document: ${linkErr.message}`);
  }

  return { documentId, versionId, path };
}

export async function signedCommercialPdfUrl(
  admin: ReturnType<typeof createAdminClient>,
  filePath: string,
  expirySeconds = 3600,
): Promise<string | null> {
  const { data, error } = await admin.storage
    .from(DOCUMENTS_BUCKET)
    .createSignedUrl(filePath, expirySeconds);
  if (error || !data?.signedUrl) return null;
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const publicUrl = Deno.env.get("EXT_SUPABASE_URL") ?? supabaseUrl;
  return data.signedUrl.replace(supabaseUrl, publicUrl);
}

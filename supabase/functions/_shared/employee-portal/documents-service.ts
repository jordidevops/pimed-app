import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
/** URL accessible des del navegador (en local, SUPABASE_URL és http://kong:8000). */
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;
const DOCUMENTS_BUCKET = "documents";

export interface PortalDocumentRow {
  id: string;
  assignment_kind: string;
  title: string;
  published_at: string;
  acknowledged_at: string | null;
  requires_signature: boolean;
  signature_submission_id: string | null;
  signature_completed: boolean;
  employee_sign_url: string | null;
  is_pending: boolean;
  document_version_id: string;
  mime_type: string | null;
  storage_path: string | null;
  view_url?: string | null;
}

export interface PortalDocumentsPayload {
  employee_id: string;
  documents: PortalDocumentRow[];
  settings: {
    requires_signature: boolean;
    required_before_punch: boolean;
  };
}

export class DocumentsError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "DocumentsError";
  }
}

export async function listPortalDocuments(
  employee_id: string,
  tenant_id: string,
  token_id: string,
): Promise<PortalDocumentsPayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_list_documents", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });

  if (error) {
    throw new DocumentsError("documents_load_failed", 500, error.message);
  }

  const payload = data as PortalDocumentsPayload;
  const documents = await Promise.all(
    (payload.documents ?? []).map(async (doc) => ({
      ...doc,
      view_url: await createDocumentViewUrl(doc.storage_path),
    })),
  );

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_documents",
    http_status: 200,
  }).catch(() => undefined);

  return { ...payload, documents };
}

async function createDocumentViewUrl(storagePath: string | null): Promise<string | null> {
  if (!storagePath || storagePath.startsWith("http")) {
    return storagePath;
  }

  const db = createAdminClient();
  const { data, error } = await db.storage
    .from(DOCUMENTS_BUCKET)
    .createSignedUrl(storagePath, 3600);

  if (error || !data?.signedUrl) {
    return null;
  }
  return data.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL);
}

export async function acknowledgePortalDocument(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  assignment_id: string,
): Promise<{ acknowledged_at: string }> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_acknowledge_document", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_assignment_id: assignment_id,
  });

  if (error) {
    const message = error.message ?? "ack_failed";
    if (message.includes("signature_required")) {
      throw new DocumentsError("signature_required", 409, message);
    }
    if (message.includes("assignment_not_found")) {
      throw new DocumentsError("assignment_not_found", 404, message);
    }
    throw new DocumentsError("ack_failed", 500, message);
  }

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "acknowledge_document",
    http_status: 200,
  }).catch(() => undefined);

  return { acknowledged_at: String(data) };
}

export async function hasPendingProtocol(
  employee_id: string,
  tenant_id: string,
): Promise<boolean> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("employee_portal_has_pending_protocol", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });

  if (error) {
    console.warn("[employee-portal] hasPendingProtocol failed:", error.message);
    return false;
  }

  return Boolean(data);
}

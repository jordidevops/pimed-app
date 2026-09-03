import type { createAdminClient } from "./supabase.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "native-signing-email";

const DOCUMENTS_BUCKET = "documents";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_PUBLIC_URL = Deno.env.get("EXT_SUPABASE_URL") ?? SUPABASE_URL;

type AdminClient = ReturnType<typeof createAdminClient>;

export async function createSignedDocumentDownloadUrl(
  adminClient: AdminClient,
  versionId: string,
): Promise<string | null> {
  const { data: version } = await adminClient
    .from("document_versions")
    .select("file_path_or_url")
    .eq("id", versionId)
    .maybeSingle();

  if (!version?.file_path_or_url) return null;

  const { data: signed, error } = await adminClient.storage
    .from(DOCUMENTS_BUCKET)
    .createSignedUrl(version.file_path_or_url as string, 7 * 24 * 3600);

  if (error || !signed) return null;
  return signed.signedUrl.replace(SUPABASE_URL, SUPABASE_PUBLIC_URL);
}

export async function enqueueNativeSigningRequestEmail(
  adminClient: AdminClient,
  opts: {
    tenantId:      string;
    sessionId:     string;
    toEmail:       string;
    signerName:    string | null;
    signerRole:    string | null;
    documentTitle: string;
    signLink:      string;
    expiresAt:     string;
    currentOrder?: number;
    totalSigners?: number;
    isNextSigner?: boolean;
  },
): Promise<{ queued: boolean; error?: string; log_id?: string }> {
  const order = opts.currentOrder ?? 1;
  const total = opts.totalSigners ?? 1;
  const eventType = opts.isNextSigner ? "signing.request.next_signer" : "signing.request.initial";

  const { data, error } = await adminClient.rpc("enqueue_email", {
    payload: {
      tenant_id:       opts.tenantId,
      idempotency_key: `native-sign-req-${opts.sessionId}`,
      to:              [opts.toEmail],
      event_type:      eventType,
      subject:         `${opts.documentTitle} — Signatura requerida`,
      template_variables: {
        signer_name:    opts.signerName ?? "Signant",
        signer_email:   opts.toEmail,
        signer_role:    opts.signerRole ?? "",
        document_title: opts.documentTitle,
        signing_url:    opts.signLink,
        current_order:  order,
        total_signers:  total,
      },
      email_type: "transactional",
      locale:     "ca",
      metadata: {
        source:     "native_signing",
        session_id: opts.sessionId,
        expires_at: opts.expiresAt,
      },
    },
  });

  if (error) {
    log("warn", FEATURE, "Request email enqueue failed", {
      tenantId: opts.tenantId,
      extra: { session_id: opts.sessionId, error: error.message },
    });
    return { queued: false, error: error.message };
  }
  const logId = typeof data === "string" ? data : (data as string | null) ?? undefined;
  return { queued: true, log_id: logId };
}

export async function enqueueNativeSigningConfirmationEmail(
  adminClient: AdminClient,
  opts: {
    tenantId:          string;
    sessionId:         string;
    toEmail:           string;
    signerName:        string | null;
    documentTitle:     string;
    signedDocumentUrl: string;
    signedAt:          string;
    groupKey?:         string | null;
  },
): Promise<{ queued: boolean; error?: string; log_id?: string }> {
  const groupKey = opts.groupKey ?? opts.sessionId;
  const { data, error } = await adminClient.rpc("enqueue_email", {
    payload: {
      tenant_id:       opts.tenantId,
      idempotency_key: `native-sign-confirm-${groupKey}-${opts.toEmail}`,
      to:              [opts.toEmail],
      event_type:      "signing.confirmation",
      subject:         `${opts.documentTitle} — Document signat`,
      template_variables: {
        signer_name:          opts.signerName ?? "Signant",
        document_title:       opts.documentTitle,
        signed_at:            opts.signedAt,
        signed_document_url:  opts.signedDocumentUrl,
      },
      email_type: "transactional",
      locale:     "ca",
      metadata: {
        source:     "native_signing",
        session_id: opts.sessionId,
      },
    },
  });

  if (error) {
    log("warn", FEATURE, "Confirmation email enqueue failed", {
      tenantId: opts.tenantId,
      extra: { session_id: opts.sessionId, error: error.message },
    });
    return { queued: false, error: error.message };
  }
  const logId = typeof data === "string" ? data : (data as string | null) ?? undefined;
  return { queued: true, log_id: logId };
}

export function buildNativeSignLink(token: string): string {
  const base = (Deno.env.get("TENANT_PORTAL_URL") ?? "http://localhost:5173").replace(/\/$/, "");
  return `${base}/sign/${token}`;
}

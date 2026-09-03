/**
 * Resol attachments d'email des de Storage i els prepara per a Resend.
 */
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export const EMAIL_ATTACHMENTS_BUCKET = "email-attachments";
export const MAX_EMAIL_ATTACHMENTS = 10;
export const MAX_EMAIL_ATTACHMENTS_TOTAL_BYTES = 25 * 1024 * 1024;
export const MAX_PORTAL_QR_ATTACHMENT_BYTES = 256 * 1024;

export interface EmailAttachmentRef {
  filename: string;
  storage_path: string;
  content_type?: string;
  content_id?: string;
}

export interface ResendAttachmentPayload {
  filename: string;
  content: string;
  content_type?: string;
  content_id?: string;
}

const ALLOWED_MIME_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/jpg",
  "application/pdf",
]);

function isAllowedStoragePath(storagePath: string, tenantId: string): boolean {
  const normalized = storagePath.replace(/^\/+/, "");
  if (normalized.includes("..")) return false;
  const parts = normalized.split("/");
  if (parts.length < 3) return false;
  if (parts[0] !== tenantId) return false;
  if (parts[1] !== "employee-portal") return false;
  return true;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

export async function resolveEmailAttachmentsForResend(
  adminClient: SupabaseClient,
  tenantId: string,
  attachments: EmailAttachmentRef[] | null | undefined,
): Promise<ResendAttachmentPayload[]> {
  if (!attachments?.length) return [];

  if (attachments.length > MAX_EMAIL_ATTACHMENTS) {
    throw new Error(`attachment_limit_exceeded: max ${MAX_EMAIL_ATTACHMENTS}`);
  }

  const resolved: ResendAttachmentPayload[] = [];
  let totalBytes = 0;

  for (const attachment of attachments) {
    const storagePath = attachment.storage_path?.trim();
    const filename = attachment.filename?.trim();
    if (!storagePath || !filename) {
      throw new Error("attachment_invalid: missing filename or storage_path");
    }
    if (!isAllowedStoragePath(storagePath, tenantId)) {
      throw new Error(`attachment_path_forbidden: ${storagePath}`);
    }

    const { data, error } = await adminClient.storage
      .from(EMAIL_ATTACHMENTS_BUCKET)
      .download(storagePath);

    if (error || !data) {
      throw new Error(`attachment_download_failed: ${storagePath}`);
    }

    const bytes = new Uint8Array(await data.arrayBuffer());
    totalBytes += bytes.length;

    if (attachment.content_id === "employee-portal-qr" && bytes.length > MAX_PORTAL_QR_ATTACHMENT_BYTES) {
      throw new Error("attachment_qr_too_large");
    }
    if (totalBytes > MAX_EMAIL_ATTACHMENTS_TOTAL_BYTES) {
      throw new Error("attachment_total_size_exceeded");
    }

    const contentType = attachment.content_type?.trim() ||
      (filename.toLowerCase().endsWith(".png") ? "image/png" : "application/octet-stream");
    if (!ALLOWED_MIME_TYPES.has(contentType)) {
      throw new Error(`attachment_mime_forbidden: ${contentType}`);
    }

    const payload: ResendAttachmentPayload = {
      filename,
      content: bytesToBase64(bytes),
      content_type: contentType,
    };
    if (attachment.content_id) {
      payload.content_id = attachment.content_id;
    }
    resolved.push(payload);
  }

  return resolved;
}

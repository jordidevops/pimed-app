import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { GetObjectCommand, S3Client } from "npm:@aws-sdk/client-s3";
import { processPdfForProvider } from "./pdf-processor.ts";
import type { AiChatAttachmentInput, AiContentPart, AiProvider } from "./types.ts";

export const CHAT_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
export const CHAT_FILE_MAX_BYTES = 10 * 1024 * 1024;
export const CHAT_IMAGE_MIME_TYPES = ["image/jpeg", "image/png", "image/webp"] as const;
export const CHAT_FILE_MIME_TYPES = ["application/pdf"] as const;
export const CHAT_ATTACHMENTS_MAX = 5;
const TENANT_FILES_BUCKET = "tenant-files";

type AttachmentFileRow = {
  id: string;
  tenant_id: string;
  created_by: string | null;
  storage_key: string | null;
  storage_provider_id: string | null;
  mime_type: string | null;
  name: string | null;
  size_bytes: number | null;
  processing_status: string | null;
  node_type: string | null;
};

type StorageProviderRow = {
  id: string;
  provider_type: string;
  bucket_name: string | null;
  access_key: string;
  secret_key: string;
  endpoint_url: string | null;
  region: string | null;
};

export type AttachmentLimits = {
  maxImageSizeBytes: number;
  maxFileSizeBytes: number;
  allowedImageMimes: string[];
  allowedFileMimes: string[];
};

const DEFAULT_LIMITS: AttachmentLimits = {
  maxImageSizeBytes: CHAT_IMAGE_MAX_BYTES,
  maxFileSizeBytes: CHAT_FILE_MAX_BYTES,
  allowedImageMimes: [...CHAT_IMAGE_MIME_TYPES],
  allowedFileMimes: [...CHAT_FILE_MIME_TYPES],
};

type ResolvedAttachmentPart =
  | Extract<AiContentPart, { type: "image" }>
  | Extract<AiContentPart, { type: "file" }>;

function isPdfMime(mime: string): boolean {
  return mime === "application/pdf";
}

export async function resolveChatAttachments(
  adminClient: SupabaseClient,
  params: {
    tenantId: string;
    userId: string;
    attachments: AiChatAttachmentInput[];
    limits?: AttachmentLimits;
  },
): Promise<ResolvedAttachmentPart[]> {
  if (params.attachments.length === 0) return [];
  if (params.attachments.length > CHAT_ATTACHMENTS_MAX) {
    throw new Error(`Només es permeten ${CHAT_ATTACHMENTS_MAX} adjunts per missatge`);
  }

  const limits = params.limits ?? DEFAULT_LIMITS;
  const allowedImages = new Set(limits.allowedImageMimes.map((m) => m.toLowerCase()));
  const allowedFiles = new Set(limits.allowedFileMimes.map((m) => m.toLowerCase()));
  const resolved: ResolvedAttachmentPart[] = [];

  for (const attachment of params.attachments) {
    if (!attachment.fileId?.trim()) {
      throw new Error("Cada adjunt ha d'incloure fileId");
    }

    const mimeType = attachment.mimeType?.toLowerCase() ?? "";
    const isImage = allowedImages.has(mimeType);
    const isFile = allowedFiles.has(mimeType);
    if (!isImage && !isFile) {
      throw new Error(`Tipus d'adjunt no permès: ${mimeType || "desconegut"}`);
    }

    const file = await loadAttachmentFile(adminClient, {
      fileId: attachment.fileId,
      tenantId: params.tenantId,
      userId: params.userId,
    });

    const maxBytes = isFile ? limits.maxFileSizeBytes : limits.maxImageSizeBytes;
    const label = isFile ? "El PDF" : "La imatge";
    if ((file.size_bytes ?? 0) > maxBytes) {
      throw new Error(
        `${label} supera la mida màxima de ${Math.round(maxBytes / (1024 * 1024))} MB`,
      );
    }

    if ((file.mime_type ?? "").toLowerCase() !== mimeType) {
      throw new Error("El tipus MIME de l'adjunt no coincideix amb el fitxer");
    }

    if (isFile) {
      resolved.push({
        type: "file",
        mimeType,
        fileId: file.id,
        name: attachment.name ?? file.name ?? undefined,
        storageKey: file.storage_key ?? undefined,
      });
    } else {
      resolved.push({
        type: "image",
        mimeType,
        fileId: file.id,
        name: attachment.name ?? file.name ?? undefined,
        storageKey: file.storage_key ?? undefined,
      });
    }
  }

  return resolved;
}

async function loadAttachmentFile(
  adminClient: SupabaseClient,
  params: { fileId: string; tenantId: string; userId: string },
): Promise<AttachmentFileRow> {
  const fileId = params.fileId?.trim();
  if (!fileId) {
    throw new Error("Adjunt sense fileId vàlid");
  }

  const { data, error } = await adminClient.rpc("get_ai_chat_attachment_file_service", {
    p_file_id: fileId,
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
  });

  if (error) throw new Error(error.message);
  if (!data) throw new Error("Adjunt no trobat o sense accés");

  const file = data as AttachmentFileRow;
  if (file.node_type !== "file") throw new Error("L'adjunt ha de ser un fitxer");
  if (file.processing_status !== "done") throw new Error("La pujada de l'adjunt encara no ha finalitzat");
  if (!file.storage_key) throw new Error("L'adjunt no té emmagatzematge associat");
  if (file.created_by !== params.userId) {
    throw new Error("Només pots adjuntar fitxers que has pujat tu");
  }

  return file;
}

export async function downloadAttachmentBytes(
  adminClient: SupabaseClient,
  file: Pick<AttachmentFileRow, "storage_key" | "storage_provider_id" | "tenant_id">,
): Promise<Uint8Array> {
  if (!file.storage_key) throw new Error("storage_key missing");

  if (!file.storage_provider_id) {
    const { data, error } = await adminClient.storage
      .from(TENANT_FILES_BUCKET)
      .download(file.storage_key);
    if (error || !data) {
      throw new Error(`No s'ha pogut descarregar l'adjunt: ${error?.message ?? "desconegut"}`);
    }
    return new Uint8Array(await data.arrayBuffer());
  }

  const { data: providerRows, error: providerError } = await adminClient.rpc(
    "get_storage_provider_with_secret",
    {
      p_tenant_id: file.tenant_id,
      p_provider_id: file.storage_provider_id,
    },
  );
  if (providerError || !providerRows?.length) {
    throw new Error("No s'ha pogut resoldre el proveïdor d'emmagatzematge");
  }

  const provider = providerRows[0] as StorageProviderRow;
  return await downloadFromByos(provider, file.storage_key);
}

async function downloadFromByos(
  provider: StorageProviderRow,
  storageKey: string,
): Promise<Uint8Array> {
  const clientConfig: ConstructorParameters<typeof S3Client>[0] = {
    region: provider.region ?? "us-east-1",
    credentials: {
      accessKeyId: provider.access_key,
      secretAccessKey: provider.secret_key,
    },
  };

  if (provider.endpoint_url) {
    clientConfig.endpoint = provider.endpoint_url;
    clientConfig.forcePathStyle = provider.provider_type === "r2";
  }

  const s3 = new S3Client(clientConfig);
  const response = await s3.send(new GetObjectCommand({
    Bucket: provider.bucket_name ?? undefined,
    Key: storageKey,
  }));

  if (!response.Body) throw new Error("Objecte buit a l'emmagatzematge");
  const bytes = await response.Body.transformToByteArray();
  return new Uint8Array(bytes);
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

export async function hydrateMediaPartsForProvider(
  adminClient: SupabaseClient,
  tenantId: string,
  userId: string,
  provider: AiProvider,
  parts: AiContentPart[],
): Promise<HydratedUserContent> {
  const hydrated: HydratedUserContent = [];

  for (const part of parts) {
    if (part.type === "text") {
      hydrated.push(part);
      continue;
    }

    if (!part.fileId?.trim()) {
      throw new Error("Missatge amb adjunt sense fileId (replay corrupte o dades antigues)");
    }

    const fileRow = await loadAttachmentFile(adminClient, {
      fileId: part.fileId,
      tenantId,
      userId,
    });
    const bytes = await downloadAttachmentBytes(adminClient, fileRow);

    if (part.type === "image") {
      hydrated.push({
        type: "image",
        mimeType: part.mimeType,
        base64: bytesToBase64(bytes),
      });
      continue;
    }

    if (part.type === "file" && isPdfMime(part.mimeType)) {
      const pdfParts = await processPdfForProvider(
        bytes,
        part.name ?? fileRow.name ?? "document.pdf",
        provider,
      );
      hydrated.push(...pdfParts);
      continue;
    }

    throw new Error(`Tipus d'adjunt no suportat: ${part.mimeType}`);
  }

  return hydrated;
}

export async function hydrateMultimodalMessages(
  adminClient: SupabaseClient,
  tenantId: string,
  userId: string,
  provider: AiProvider,
  messages: Array<{ role: string; content: string | AiContentPart[] }>,
): Promise<Array<{ role: string; content: string | HydratedUserContent }>> {
  const result: Array<{ role: string; content: string | HydratedUserContent }> = [];

  for (const message of messages) {
    if (message.role !== "user" || !Array.isArray(message.content)) {
      result.push({
        role: message.role,
        content: message.content as string | HydratedUserContent,
      });
      continue;
    }

    const hasMedia = message.content.some((part) => part.type === "image" || part.type === "file");
    if (!hasMedia) {
      result.push({ role: message.role, content: message.content as string | HydratedUserContent });
      continue;
    }

    const hydratedParts = await hydrateMediaPartsForProvider(
      adminClient,
      tenantId,
      userId,
      provider,
      message.content,
    );
    result.push({ role: message.role, content: hydratedParts });
  }

  return result;
}

export type HydratedUserContent = Array<
  | { type: "text"; text: string }
  | { type: "image"; mimeType: string; base64: string }
  | { type: "file"; mimeType: string; base64: string }
>;

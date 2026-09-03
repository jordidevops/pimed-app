import type { AiContentPart, AiMessage } from "./types.ts";

export function isContentParts(content: AiMessage["content"]): content is AiContentPart[] {
  return Array.isArray(content);
}

export function getMessageTextContent(content: AiMessage["content"]): string {
  if (typeof content === "string") return content;
  return content
    .filter((part): part is Extract<AiContentPart, { type: "text" }> => part.type === "text")
    .map((part) => part.text)
    .join("\n")
    .trim();
}

export function messageHasImages(content: AiMessage["content"]): boolean {
  return isContentParts(content) && content.some((part) => part.type === "image");
}

export function messageHasMediaAttachments(content: AiMessage["content"]): boolean {
  return isContentParts(content) && content.some((part) => part.type === "image" || part.type === "file");
}

export function buildUserMessageContent(
  text: string,
  mediaParts: Array<Extract<AiContentPart, { type: "image" | "file" }>>,
): string | AiContentPart[] {
  const trimmed = text.trim();
  if (mediaParts.length === 0) return trimmed;

  const parts: AiContentPart[] = [];
  if (trimmed) parts.push({ type: "text", text: trimmed });
  parts.push(...mediaParts);
  return parts;
}

function attachmentFallbackLabel(content: AiContentPart[]): string {
  const hasImage = content.some((part) => part.type === "image");
  const hasFile = content.some((part) => part.type === "file");
  if (hasImage && hasFile) return "[Adjunts]";
  if (hasFile) return "[PDF adjunt]";
  if (hasImage) return "[Imatge adjunta]";
  return "";
}

export function serializeUserMessageForDb(content: string | AiContentPart[]): {
  content: string;
  payload: Record<string, unknown>;
} {
  if (typeof content === "string") {
    return { content, payload: {} };
  }

  const text = getMessageTextContent(content);
  const media = content.filter(
    (part): part is Extract<AiContentPart, { type: "image" | "file" }> =>
      part.type === "image" || part.type === "file",
  );
  const fallback = text || attachmentFallbackLabel(content);

  const payload: Record<string, unknown> = {
    user_parts: content,
  };

  if (media.length > 0) {
    payload.attachments = media.map((part) => ({
      fileId: part.fileId,
      mimeType: part.mimeType,
      name: part.name ?? null,
      storageKey: part.storageKey ?? null,
      kind: part.type,
    }));
  }

  return { content: fallback, payload };
}

export function parseUserPartsFromPayload(payload: Record<string, unknown> | null | undefined):
  AiContentPart[] | null {
  if (!payload) return null;

  if (Array.isArray(payload.user_parts)) {
    const normalized = normalizeUserParts(payload.user_parts);
    return normalized.length > 0 ? normalized : null;
  }

  if (Array.isArray(payload.attachments)) {
    const media = normalizeUserParts(
      (payload.attachments as Record<string, unknown>[]).map((attachment) => ({
        type: attachment.kind === "file" || attachment.mimeType === "application/pdf"
          ? "file"
          : "image",
        fileId: attachment.fileId ?? attachment.file_id,
        mimeType: attachment.mimeType ?? attachment.mime_type,
        name: attachment.name,
        storageKey: attachment.storageKey ?? attachment.storage_key,
      })),
    ).filter((part) => part.type === "image" || part.type === "file");
    if (media.length > 0) return media;
  }

  return null;
}

function normalizeUserParts(rawParts: unknown[]): AiContentPart[] {
  const normalized: AiContentPart[] = [];

  for (const raw of rawParts) {
    if (!raw || typeof raw !== "object") continue;
    const part = raw as Record<string, unknown>;

    if (part.type === "text" && typeof part.text === "string") {
      normalized.push({ type: "text", text: part.text });
      continue;
    }

    if (part.type !== "image" && part.type !== "file") continue;

    const fileId = part.fileId ?? part.file_id;
    if (typeof fileId !== "string" || !fileId.trim()) continue;

    const mimeType = String(part.mimeType ?? part.mime_type ?? "application/octet-stream");
    const resolvedType = part.type === "file" || mimeType === "application/pdf" ? "file" : "image";

    normalized.push({
      type: resolvedType,
      fileId: fileId.trim(),
      mimeType,
      name: typeof part.name === "string" ? part.name : undefined,
      storageKey: typeof (part.storageKey ?? part.storage_key) === "string"
        ? String(part.storageKey ?? part.storage_key)
        : undefined,
    });
  }

  return normalized;
}

export function estimateTokensForContent(content: AiMessage["content"]): number {
  let tokens = 256;
  if (typeof content === "string") {
    tokens += Math.ceil(content.length / 4);
  } else {
    for (const part of content) {
      if (part.type === "text") tokens += Math.ceil(part.text.length / 4);
      if (part.type === "image") tokens += 2000;
      if (part.type === "file") tokens += 4000;
    }
  }
  return tokens;
}

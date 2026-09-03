import { uploadFile } from '@/features/storage/api/storageService'
import { StorageServiceError } from '@/features/storage/types/storage.types'

export const CHAT_ATTACHMENTS_MAX = 5
export const CHAT_IMAGE_MAX_BYTES = 5 * 1024 * 1024
export const CHAT_FILE_MAX_BYTES = 10 * 1024 * 1024
export const CHAT_IMAGE_MIME_TYPES = ['image/jpeg', 'image/png', 'image/webp'] as const
export const CHAT_FILE_MIME_TYPES = ['application/pdf'] as const
export const CHAT_ATTACHMENT_MIME_TYPES = [...CHAT_IMAGE_MIME_TYPES, ...CHAT_FILE_MIME_TYPES] as const

export type ChatAttachmentKind = 'image' | 'file'

export type ChatAttachmentRef = {
  fileId: string
  mimeType: string
  name: string
  storageKey: string
  previewUrl: string
  kind: ChatAttachmentKind
}

export function isPdfMime(mime: string): boolean {
  return mime.toLowerCase() === 'application/pdf'
}

export function attachmentKindForMime(mime: string): ChatAttachmentKind {
  return isPdfMime(mime) ? 'file' : 'image'
}

export function validateChatAttachmentFile(
  file: File,
  limits: {
    maxImageBytes: number
    maxFileBytes: number
    allowedImageMimes: readonly string[]
    allowedFileMimes: readonly string[]
  },
): string | null {
  const mime = file.type.toLowerCase()
  const isImage = limits.allowedImageMimes.includes(mime)
  const isFile = limits.allowedFileMimes.includes(mime)

  if (!isImage && !isFile) {
    return 'Només es permeten imatges JPEG, PNG, WebP o PDF'
  }

  const maxBytes = isFile ? limits.maxFileBytes : limits.maxImageBytes
  const label = isFile ? 'El PDF' : 'La imatge'
  if (file.size > maxBytes) {
    const mb = Math.round(maxBytes / (1024 * 1024))
    return `${label} no pot superar ${mb} MB`
  }

  return null
}

/** @deprecated use validateChatAttachmentFile */
export function validateChatImageFile(
  file: File,
  maxBytes: number = CHAT_IMAGE_MAX_BYTES,
  allowedMimes: readonly string[] = CHAT_IMAGE_MIME_TYPES,
): string | null {
  return validateChatAttachmentFile(file, {
    maxImageBytes: maxBytes,
    maxFileBytes: maxBytes,
    allowedImageMimes: allowedMimes,
    allowedFileMimes: [],
  })
}

function uniqueChatFileName(originalName: string): string {
  const ext = originalName.includes('.') ? originalName.split('.').pop() : 'bin'
  return `ai-chat-${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`
}

export async function uploadChatAttachment(
  tenantId: string,
  file: File,
  limits: {
    maxImageBytes: number
    maxFileBytes: number
    allowedImageMimes: readonly string[]
    allowedFileMimes: readonly string[]
  },
): Promise<ChatAttachmentRef> {
  const validationError = validateChatAttachmentFile(file, limits)
  if (validationError) throw new Error(validationError)

  const kind = attachmentKindForMime(file.type)
  const previewUrl = kind === 'image' ? URL.createObjectURL(file) : ''

  try {
    const result = await uploadFile({
      tenant_id: tenantId,
      file: new File([file], uniqueChatFileName(file.name), { type: file.type }),
      parent_id: null,
      storage_provider_id: null,
      metadata: { source: 'ai-chat' },
    })

    return {
      fileId: result.node_id,
      mimeType: file.type,
      name: file.name,
      storageKey: result.storage_key,
      previewUrl,
      kind,
    }
  } catch (err) {
    if (previewUrl) URL.revokeObjectURL(previewUrl)
    if (err instanceof StorageServiceError) {
      throw new Error(err.message)
    }
    throw err
  }
}

/** @deprecated use uploadChatAttachment */
export async function uploadChatImage(
  tenantId: string,
  file: File,
  maxBytes: number = CHAT_IMAGE_MAX_BYTES,
): Promise<ChatAttachmentRef> {
  return uploadChatAttachment(tenantId, file, {
    maxImageBytes: maxBytes,
    maxFileBytes: maxBytes,
    allowedImageMimes: CHAT_IMAGE_MIME_TYPES,
    allowedFileMimes: [],
  })
}

export function revokeAttachmentPreviews(attachments: ChatAttachmentRef[]) {
  for (const attachment of attachments) {
    if (attachment.previewUrl?.startsWith('blob:')) {
      URL.revokeObjectURL(attachment.previewUrl)
    }
  }
}

export type ChatMessageAttachmentMeta = {
  fileId: string
  mimeType: string
  name?: string | null
  kind?: ChatAttachmentKind
}

export function getMessageAttachments(payload: Record<string, unknown> | null): ChatMessageAttachmentMeta[] {
  if (!payload) return []

  if (Array.isArray(payload.attachments)) {
    return (payload.attachments as ChatMessageAttachmentMeta[]).filter((item) => item?.fileId)
  }

  if (Array.isArray(payload.user_parts)) {
    return (payload.user_parts as Array<{ type?: string; fileId?: string; mimeType?: string; name?: string }>)
      .filter((part) => (part.type === 'image' || part.type === 'file') && part.fileId)
      .map((part) => ({
        fileId: part.fileId!,
        mimeType: part.mimeType ?? (part.type === 'file' ? 'application/pdf' : 'image/jpeg'),
        name: part.name,
        kind: part.type === 'file' ? 'file' : 'image',
      }))
  }

  return []
}

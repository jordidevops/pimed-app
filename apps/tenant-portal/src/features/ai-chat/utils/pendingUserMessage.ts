import type { ChatAttachmentRef, ChatMessageAttachmentMeta } from '@/features/ai-chat/utils/chatAttachments'

export type PendingUserMessage = {
  content: string
  attachments: Array<ChatMessageAttachmentMeta & { previewUrl?: string }>
}

export function buildPendingUserMessage(
  text: string,
  attachments: ChatAttachmentRef[],
): PendingUserMessage {
  return {
    content: text,
    attachments: attachments.map((a) => ({
      fileId: a.fileId,
      mimeType: a.mimeType,
      name: a.name,
      kind: a.kind,
      previewUrl: a.previewUrl,
    })),
  }
}

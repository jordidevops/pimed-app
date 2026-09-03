import { FileText } from 'lucide-react'
import { ChatMessageImage } from './ChatMessageImage'
import { isPdfMime, type ChatMessageAttachmentMeta } from '../utils/chatAttachments'

type ChatMessageAttachmentProps = {
  attachment: ChatMessageAttachmentMeta
  variant?: 'user' | 'assistant'
}

export function ChatMessageAttachment({ attachment, variant = 'assistant' }: ChatMessageAttachmentProps) {
  if (attachment.kind === 'file' || isPdfMime(attachment.mimeType)) {
    return (
      <div
        className={
          variant === 'user'
            ? 'flex items-center gap-2 rounded-lg border border-white/20 bg-white/10 px-3 py-2 text-xs'
            : 'flex items-center gap-2 rounded-lg border bg-background px-3 py-2 text-xs text-muted-foreground'
        }
      >
        <FileText className="h-4 w-4 shrink-0" />
        <span className="truncate">{attachment.name ?? 'Document PDF'}</span>
      </div>
    )
  }

  return (
    <ChatMessageImage
      fileId={attachment.fileId}
      alt={attachment.name ?? undefined}
      className={variant === 'user' ? 'h-24 w-24 rounded-lg border object-cover' : undefined}
    />
  )
}

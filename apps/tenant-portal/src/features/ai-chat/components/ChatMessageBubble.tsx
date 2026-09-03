import { cn } from '@/lib/utils'
import { Loader2 } from 'lucide-react'
import type { AiChatUiBlock } from '../schemas/chartBlock'
import type { ChatMessageAttachmentMeta } from '../utils/chatAttachments'
import { ChatMessageAttachment } from './ChatMessageAttachment'
import { ChatMessageMarkdown } from './ChatMessageMarkdown'
import { ChatUiBlockRenderer } from './ChatUiBlockRenderer'

import type { OrchestratorSource } from '@/features/signing'

type ChatMessageBubbleProps = {
  role: 'user' | 'assistant'
  content: string | null
  attachments?: ChatMessageAttachmentMeta[]
  uiBlocks?: AiChatUiBlock[]
  messageId?: string
  streaming?: boolean
  latencyLabel?: string
  consumedGeneratorKeys?: ReadonlySet<string>
  onOpenDocumentGenerator?: (
    source: OrchestratorSource,
    entityContext?: { type: string; id: string; label?: string; email?: string },
    blockKey?: string,
  ) => void
}

export function ChatMessageBubble({
  role,
  content,
  attachments = [],
  uiBlocks,
  messageId,
  streaming,
  latencyLabel,
  consumedGeneratorKeys,
  onOpenDocumentGenerator,
}: ChatMessageBubbleProps) {
  return (
    <div
      className={cn(
        'rounded-xl px-4 py-3 text-sm max-w-[85%]',
        role === 'user'
          ? 'ml-auto bg-indigo-600 text-white'
          : 'bg-muted',
      )}
    >
      {role === 'user' ? (
        <div className="space-y-2">
          {attachments.map((attachment) => (
            <ChatMessageAttachment
              key={attachment.fileId}
              attachment={attachment}
              variant="user"
            />
          ))}
          {content?.trim() && !(content === '[Imatge adjunta]' && attachments.length > 0) && !(content === '[PDF adjunt]' && attachments.some((a) => a.kind === 'file' || a.mimeType === 'application/pdf')) && !(content === '[Adjunts]' && attachments.length > 0) ? (
            <p className="whitespace-pre-wrap">{content}</p>
          ) : null}
        </div>
      ) : (
        <>
          {content?.trim() ? (
            <ChatMessageMarkdown content={content} />
          ) : null}
          {streaming ? (
            <Loader2 className="inline-block h-3.5 w-3.5 ml-1 align-text-bottom animate-spin opacity-70" />
          ) : null}
          {uiBlocks?.length ? (
            <ChatUiBlockRenderer
              blocks={uiBlocks}
              messageId={messageId}
              onOpenDocumentGenerator={onOpenDocumentGenerator}
              consumedGeneratorKeys={consumedGeneratorKeys}
            />
          ) : null}
          {latencyLabel ? (
            <p className="mt-2 text-[11px] text-muted-foreground">{latencyLabel}</p>
          ) : null}
        </>
      )}
    </div>
  )
}

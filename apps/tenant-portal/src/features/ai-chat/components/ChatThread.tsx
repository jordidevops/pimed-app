import { RefreshCw } from 'lucide-react'
import type { AiMessageRow, AiChatProposal } from '../api/chatApi'
import type { AiChatUiBlock, DocumentResultUiBlock } from '../schemas/chartBlock'
import { formatMessageLatency, getMessageLatencyMs, getMessageUiBlocks } from '../api/chatApi'
import { getMessageAttachments } from '../utils/chatAttachments'
import type { PendingUserMessage } from '../utils/pendingUserMessage'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { ChatMessageBubble } from './ChatMessageBubble'
import { ChatMessageAttachment } from './ChatMessageAttachment'

import { ChatProposalCard } from './ChatProposalCard'
import type { OrchestratorSource } from '@/features/signing'

type ChatThreadProps = {
  messages: AiMessageRow[]
  loading: boolean
  thinking: boolean
  streamingContent?: string | null
  pendingUser?: PendingUserMessage | null
  hideLastAssistant?: boolean
  canRegenerate?: boolean
  onRegenerate?: () => void
  proposals?: AiChatProposal[]
  onApplyProposal?: (proposalToken: string) => Promise<void>
  onOpenDocumentFromProposal?: (proposal: AiChatProposal) => Promise<void>
  onProposalError?: (message: string) => void
  onOpenDocumentGenerator?: (
    source: OrchestratorSource,
    entityContext?: { type: string; id: string; label?: string; email?: string },
    blockKey?: string,
  ) => void
  consumedGeneratorKeys?: ReadonlySet<string>
  ephemeralDocumentResult?: DocumentResultUiBlock | null
  pendingUiBlocks?: AiChatUiBlock[] | null
}
export function ChatThread({
  messages,
  loading,
  thinking,
  streamingContent,
  pendingUser,
  hideLastAssistant = false,
  canRegenerate = false,
  onRegenerate,
  proposals = [],
  onApplyProposal,
  onOpenDocumentFromProposal,
  onProposalError,
  onOpenDocumentGenerator,
  consumedGeneratorKeys,
  ephemeralDocumentResult = null,
  pendingUiBlocks = null,
}: ChatThreadProps) {  const { t } = useTranslation('chat')
  const latestUserMessage = [...messages].reverse().find((m) => m.role === 'user')

  const hasCommittedPendingUser = (() => {
    if (!pendingUser || !latestUserMessage) return false

    const latestUserContent = (latestUserMessage.content ?? '').trim()
    if (latestUserContent !== pendingUser.content.trim()) return false

    const latestAttachmentIds = getMessageAttachments(latestUserMessage.payload).map((a) => a.fileId).sort()
    const pendingAttachmentIds = pendingUser.attachments.map((a) => a.fileId).sort()
    if (latestAttachmentIds.length !== pendingAttachmentIds.length) return false

    return latestAttachmentIds.every((id, idx) => id === pendingAttachmentIds[idx])
  })()

  const lastAssistantId = [...messages].reverse().find((m) => m.role === 'assistant')?.id

  const filtered = messages.filter((m) => {
    if (m.role !== 'user' && m.role !== 'assistant') return false
    if (m.role === 'assistant' && !(m.content ?? '').trim() && getMessageUiBlocks(m).length === 0) return false
    if (
      streamingContent !== null
      && m.role === 'assistant'
      && messages[messages.length - 1]?.id === m.id
    ) {
      return false
    }
    if (hideLastAssistant && m.role === 'assistant' && m.id === lastAssistantId) {
      return false
    }
    return true
  })
  const visible = filtered.filter((m, index) => {
    if (m.role !== 'user' || index === 0) return true
    const prev = filtered[index - 1]
    if (!prev || prev.role !== 'user') return true

    const currentContent = (m.content ?? '').trim()
    const prevContent = (prev.content ?? '').trim()
    if (currentContent !== prevContent) return true

    const currentAttachmentIds = getMessageAttachments(m.payload).map((a) => a.fileId).sort()
    const prevAttachmentIds = getMessageAttachments(prev.payload).map((a) => a.fileId).sort()
    if (currentAttachmentIds.length !== prevAttachmentIds.length) return true

    return !currentAttachmentIds.every((id, idx) => id === prevAttachmentIds[idx])
  })

  const pendingProposals = proposals.filter((p) => p.status === 'pending' || p.status === 'applied')

  return (
    <div className="flex-1 min-h-0 overflow-y-auto p-4">
      <div className="max-w-3xl mx-auto space-y-4">
        {loading && visible.length === 0 && !pendingUser && (
          <p className="text-muted-foreground text-sm">…</p>
        )}
        {visible.map((m) => (
          <div key={m.id} className={m.role === 'assistant' ? 'space-y-1' : undefined}>
            <ChatMessageBubble
              role={m.role as 'user' | 'assistant'}
              content={m.content}
              attachments={getMessageAttachments(m.payload)}
              uiBlocks={getMessageUiBlocks(m)}
              messageId={m.id}
              onOpenDocumentGenerator={onOpenDocumentGenerator}
              consumedGeneratorKeys={consumedGeneratorKeys}
              latencyLabel={
                m.role === 'assistant' && getMessageLatencyMs(m) != null
                  ? formatMessageLatency(getMessageLatencyMs(m)!)
                  : undefined
              }
            />
            {m.role === 'assistant'
              && m.id === lastAssistantId
              && pendingProposals.length > 0
              && !thinking
              && streamingContent === null && (
                <div className="space-y-2 mt-2">
                  {pendingProposals.map((p) => (
                    <ChatProposalCard
                      key={p.id}
                      proposal={p}
                      onApply={async (token) => {
                        if (!onApplyProposal) throw new Error('No disponible')
                        await onApplyProposal(token)
                      }}
                      onOpenDocumentGenerator={
                        p.toolName === 'propose_generate_document' && onOpenDocumentFromProposal
                          ? () => onOpenDocumentFromProposal(p)
                          : undefined
                      }
                      onError={onProposalError}
                    />
                  ))}
                </div>
              )}
            {m.role === 'assistant'
              && m.id === lastAssistantId
              && canRegenerate
              && !thinking
              && streamingContent === null
              && onRegenerate && (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="h-7 text-xs text-muted-foreground gap-1.5"
                  onClick={onRegenerate}
                >
                  <RefreshCw className="h-3.5 w-3.5" />
                  {t('regenerate', 'Regenerar resposta')}
                </Button>
              )}
          </div>
        ))}        {pendingUser && !hasCommittedPendingUser && (
          <div className="rounded-xl px-4 py-3 text-sm max-w-[85%] ml-auto bg-indigo-600 text-white">
            <div className="space-y-2">
              {pendingUser.attachments.map((attachment) => (
                <ChatMessageAttachment
                  key={attachment.fileId}
                  attachment={{
                    fileId: attachment.fileId,
                    mimeType: attachment.mimeType,
                    name: attachment.name,
                    kind: attachment.kind ?? (attachment.previewUrl ? 'image' : 'file'),
                  }}
                  variant="user"
                />
              ))}
              {pendingUser.content ? (
                <p className="whitespace-pre-wrap">{pendingUser.content}</p>
              ) : null}
            </div>
          </div>
        )}
        {streamingContent !== null && (
          <ChatMessageBubble
            role="assistant"
            content={streamingContent ?? null}
            streaming={thinking}
            messageId="streaming"
            uiBlocks={pendingUiBlocks ?? undefined}
            onOpenDocumentGenerator={onOpenDocumentGenerator}
            consumedGeneratorKeys={consumedGeneratorKeys}
          />
        )}
        {thinking && streamingContent === null && (
          <p className="text-sm text-muted-foreground">{t('thinking', 'Pensant…')}</p>
        )}
        {ephemeralDocumentResult && (
          <ChatMessageBubble
            role="assistant"
            content={
              ephemeralDocumentResult.success
                ? t('documentResultAssistantMessage', 'Document generat correctament.')
                : t('documentResultAssistantError', 'No s\'ha pogut generar el document.')
            }
            uiBlocks={[ephemeralDocumentResult]}
          />
        )}
      </div>
    </div>
  )
}

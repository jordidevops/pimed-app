import { useTranslation } from 'react-i18next'
import {
  parseUiBlock,
} from '@/features/ai-chat/schemas/chartBlock'
import { ChatChartBlock } from '@/features/ai-chat/components/ChatChartBlock'
import { ChatDocumentGeneratorBlock } from '@/features/ai-chat/components/ChatDocumentGeneratorBlock'
import { ChatDocumentResultBlock } from '@/features/ai-chat/components/ChatDocumentResultBlock'
import type { OrchestratorSource } from '@/features/signing'

type ChatUiBlockRendererProps = {
  blocks: unknown[]
  messageId?: string
  onOpenDocumentGenerator?: (
    source: OrchestratorSource,
    entityContext?: { type: string; id: string; label?: string; email?: string },
    blockKey?: string,
  ) => void
  consumedGeneratorKeys?: ReadonlySet<string>
}

export function ChatUiBlockRenderer({ blocks, messageId, onOpenDocumentGenerator, consumedGeneratorKeys }: ChatUiBlockRendererProps) {
  const { t } = useTranslation('chat')

  if (!blocks.length) return null

  return (
    <div className="mt-3 space-y-3">
      {blocks.map((raw, index) => {
        const block = parseUiBlock(raw)
        if (!block) {
          return (
            <p key={index} className="text-xs text-destructive">
              {t('invalidUiBlock', 'No s\'ha pogut mostrar un element visual del missatge.')}
            </p>
          )
        }

        if (block.type === 'chart') {
          return <ChatChartBlock key={index} chart={block} />
        }
        if (block.type === 'document_generator') {
          if (!onOpenDocumentGenerator) {
            return (
              <p key={index} className="text-xs text-muted-foreground">
                {t('documentGeneratorUnavailable', 'El generador de documents no està disponible en aquesta vista.')}
              </p>
            )
          }
          const blockKey = `${messageId ?? 'unknown'}:${index}:${block.templateLocaleId}`
          const consumed = consumedGeneratorKeys?.has(blockKey)
          return (
            <ChatDocumentGeneratorBlock
              key={index}
              block={block}
              consumed={consumed}
              onOpen={(source, entityContext) => onOpenDocumentGenerator(source, entityContext, blockKey)}
            />
          )
        }
        if (block.type === 'document_result') {
          return <ChatDocumentResultBlock key={index} block={block} />
        }

        return null
      })}
    </div>
  )
}

import { useRef } from 'react'

import { AlertTriangle, FileText, ImagePlus, Loader2, Send, X } from 'lucide-react'

import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'

import { Textarea } from '@/components/ui/textarea'

import type { ChatAttachmentRef } from '@/features/ai-chat/utils/chatAttachments'

import {
  CHAT_ATTACHMENTS_MAX,
  CHAT_ATTACHMENT_MIME_TYPES,
  isPdfMime,
} from '@/features/ai-chat/utils/chatAttachments'



type ChatComposerProps = {

  value: string

  onChange: (value: string) => void

  onSend: () => void

  attachments: ChatAttachmentRef[]

  maxAttachments?: number

  onAttach: (file: File) => void

  onRemoveAttachment: (fileId: string) => void

  attaching?: boolean

  attachDisabled?: boolean

  attachDisabledReason?: string

  quotaNotice?: {
    level: 'warning' | 'error'
    message: string
  } | null

  disabled?: boolean

  sending?: boolean

}



export function ChatComposer({

  value,

  onChange,

  onSend,

  attachments,

  maxAttachments = CHAT_ATTACHMENTS_MAX,

  onAttach,

  onRemoveAttachment,

  attaching = false,

  attachDisabled = false,

  attachDisabledReason,

  quotaNotice = null,

  disabled,

  sending,

}: ChatComposerProps) {

  const { t } = useTranslation('chat')

  const fileInputRef = useRef<HTMLInputElement>(null)

  const canSend = (value.trim().length > 0 || attachments.length > 0) && !disabled && !sending && !attaching

  const atAttachmentLimit = attachments.length >= maxAttachments



  return (

    <div className="border-t p-4">

      <div className="max-w-3xl mx-auto space-y-2">

        {attachments.length > 0 && (

          <div className="flex flex-wrap gap-2">

            {attachments.map((attachment) => (

              <div key={attachment.fileId} className="relative inline-block">

                {attachment.kind === 'file' || isPdfMime(attachment.mimeType) ? (
                  <div className="flex h-24 w-36 items-center gap-2 rounded-lg border bg-muted px-3 text-xs">
                    <FileText className="h-5 w-5 shrink-0 text-muted-foreground" />
                    <span className="line-clamp-3">{attachment.name}</span>
                  </div>
                ) : (
                  <img
                    src={attachment.previewUrl}
                    alt={attachment.name}
                    className="h-24 w-24 rounded-lg border object-cover"
                  />
                )}

                <Button

                  type="button"

                  variant="secondary"

                  size="icon"

                  className="absolute -top-2 -right-2 h-7 w-7 rounded-full shadow"

                  onClick={() => onRemoveAttachment(attachment.fileId)}

                  disabled={sending || attaching}

                  aria-label={t('removeAttachment', 'Eliminar imatge')}

                >

                  <X className="h-3.5 w-3.5" />

                </Button>

              </div>

            ))}

          </div>

        )}

        {quotaNotice && (
          <div
            className={
              quotaNotice.level === 'error'
                ? 'rounded-md border border-red-300 bg-red-50 px-3 py-2 text-xs text-red-700'
                : 'rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-700'
            }
            role="status"
            aria-live="polite"
          >
            <span className="inline-flex items-center gap-1.5">
              <AlertTriangle className="h-3.5 w-3.5" />
              {quotaNotice.message}
            </span>
          </div>
        )}



        <div className="flex gap-2 items-end">

          <input

            ref={fileInputRef}

            type="file"

            accept={CHAT_ATTACHMENT_MIME_TYPES.join(',')}

            className="hidden"

            onChange={(e) => {

              const file = e.target.files?.[0]

              if (file) onAttach(file)

              e.target.value = ''

            }}

          />

          <Button

            type="button"

            variant="outline"

            size="icon"

            disabled={disabled || sending || attaching || atAttachmentLimit || attachDisabled}

            onClick={() => fileInputRef.current?.click()}

            title={

              attachDisabledReason

                ? attachDisabledReason

                : attachDisabled

                ? t('visionNotSupported', 'Aquest model no suporta adjunts multimodals.')

                : t('attachFile', 'Adjuntar imatge o PDF')

            }

            aria-label={t('attachFile', 'Adjuntar imatge o PDF')}

          >

            {attaching ? (

              <Loader2 className="h-4 w-4 animate-spin" />

            ) : (

              <ImagePlus className="h-4 w-4" />

            )}

          </Button>

          <Textarea

            value={value}

            onChange={(e) => onChange(e.target.value)}

            placeholder={t('placeholder', 'Escriu un missatge…')}

            rows={2}

            className="resize-none"

            disabled={disabled || sending || attaching}

            onKeyDown={(e) => {

              if (e.key === 'Enter' && !e.shiftKey) {

                e.preventDefault()

                if (canSend) onSend()

              }

            }}

          />

          <Button onClick={onSend} disabled={!canSend}>

            <Send className="h-4 w-4" />

            <span className="sr-only">{t('send', 'Enviar')}</span>

          </Button>

        </div>

        {attachments.length > 0 && (

          <p className="text-[11px] text-muted-foreground">

            {t('attachmentsCount', '{{count}} / {{max}} adjunts', {

              count: attachments.length,

              max: maxAttachments,

            })}

          </p>

        )}

      </div>

    </div>

  )

}



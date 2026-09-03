import { useLayoutEffect, useRef, useState, type ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { MentionAutocomplete } from './MentionAutocomplete'
import { MentionMemberDropdown } from './MentionMemberDropdown'
import {
  TimelineAttachmentPicker,
  type PendingAttachment,
} from './TimelineAttachmentPicker'
import { CommentTemplatePicker } from './CommentTemplatePicker'
import type { CommentTemplate, EntityTimelineType } from '../api/timelineService'
import {
  allocateMentionLabel,
  decodeStorageToDisplay,
  detectInlineMention,
  encodeMentionsForStorage,
  formatEditorMention,
  pruneMentionRefs,
  type MentionRef,
} from '../utils/mentionFormat'

interface TimelineComposerProps {
  entityType: EntityTimelineType
  entityId: string
  disabled?: boolean
  placeholder?: string
  mode?: 'create' | 'edit'
  initialStorageContent?: string
  initialIsTask?: boolean
  initialDueDate?: string
  submitLabel?: string
  onCancel?: () => void
  onSubmit: (
    content: string,
    isTask: boolean,
    attachments: PendingAttachment[],
    dueDate: string,
    isAiContextNote: boolean,
  ) => void
}

export function TimelineComposer({
  entityType,
  entityId,
  disabled,
  placeholder,
  mode = 'create',
  initialStorageContent,
  initialIsTask = false,
  initialDueDate = '',
  submitLabel,
  onCancel,
  onSubmit,
}: TimelineComposerProps) {
  const { t } = useTranslation('activity')
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const pendingCursorRef = useRef<number | null>(null)
  const isEdit = mode === 'edit'

  const initial = decodeStorageToDisplay(initialStorageContent ?? '')

  const [content, setContent] = useState(() => (isEdit ? initial.display : ''))
  const [mentions, setMentions] = useState<MentionRef[]>(() => (isEdit ? initial.mentions : []))
  const [isTask, setIsTask] = useState(initialIsTask)
  const [dueDate, setDueDate] = useState(initialDueDate)
  const [isAiContextNote, setIsAiContextNote] = useState(false)
  const [attachments, setAttachments] = useState<PendingAttachment[]>([])
  const [inlineMention, setInlineMention] = useState<ReturnType<typeof detectInlineMention>>(null)

  useLayoutEffect(() => {
    if (pendingCursorRef.current === null) return
    const el = textareaRef.current
    if (!el) return
    const pos = pendingCursorRef.current
    pendingCursorRef.current = null
    el.focus()
    el.setSelectionRange(pos, pos)
  }, [content])

  function applyMentionInsert(nextContent: string, nextMentions: MentionRef[], cursorPos: number) {
    pendingCursorRef.current = cursorPos
    setContent(nextContent)
    setMentions(nextMentions)
    setInlineMention(null)
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = content.trim()
    if (!trimmed && attachments.length === 0) return
    const storageContent = encodeMentionsForStorage(trimmed, mentions)
    onSubmit(storageContent, isTask, attachments, isTask ? dueDate : '', isAiContextNote)
    if (!isEdit) {
      setContent('')
      setMentions([])
      setIsTask(false)
      setDueDate('')
      setIsAiContextNote(false)
      setAttachments([])
      setInlineMention(null)
    }
  }

  function insertMention(member: { id: string; full_name: string }) {
    const label = allocateMentionLabel(member.full_name, mentions)
    const displayToken = formatEditorMention(label)
    const ref: MentionRef = { id: member.id, full_name: member.full_name, label }

    if (inlineMention) {
      const before = content.slice(0, inlineMention.start)
      const after = content.slice(inlineMention.end)
      const nextContent = before + displayToken + after
      const nextMentions = pruneMentionRefs(nextContent, [...mentions, ref])
      applyMentionInsert(nextContent, nextMentions, before.length + displayToken.length)
      return
    }

    const nextContent = content + displayToken
    applyMentionInsert(nextContent, [...mentions, ref], nextContent.length)
  }

  function handleContentChange(e: ChangeEvent<HTMLTextAreaElement>) {
    const value = e.target.value
    const cursor = e.target.selectionStart ?? value.length
    setContent(value)
    setMentions((prev) => pruneMentionRefs(value, prev))
    setInlineMention(detectInlineMention(value, cursor))
  }

  function applyTemplate(template: CommentTemplate) {
    const decoded = decodeStorageToDisplay(template.body)
    pendingCursorRef.current = decoded.display.length
    setContent(decoded.display)
    setMentions(decoded.mentions)
    setIsTask(template.default_is_task)
    setDueDate('')
    setInlineMention(null)
  }

  const canSubmit = isEdit ? content.trim().length > 0 : content.trim().length > 0 || attachments.length > 0

  return (
    <form
      onSubmit={handleSubmit}
      className={`rounded-xl border border-border bg-card p-3 space-y-2 ${isEdit ? 'border-primary/30' : ''}`}
    >
      <div className="relative">
        <textarea
          ref={textareaRef}
          value={content}
          onChange={handleContentChange}
          rows={isEdit ? 4 : 3}
          disabled={disabled}
          placeholder={
            placeholder ??
            t('timeline.composer_placeholder', "Escriu un comentari... (usa @ per mencionar)")
          }
          className="w-full resize-y rounded-md border border-input bg-background px-3 py-2 text-sm min-h-[72px]"
        />
        {inlineMention && (
          <MentionMemberDropdown query={inlineMention.query} onSelect={insertMention} />
        )}
      </div>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-3 flex-wrap">
          <MentionAutocomplete onSelect={insertMention} />
          {!isEdit && (
            <CommentTemplatePicker
              entityType={entityType}
              disabled={disabled}
              onApply={applyTemplate}
            />
          )}
          {!isEdit && (
            <TimelineAttachmentPicker
              entityType={entityType}
              entityId={entityId}
              attachments={attachments}
              onChange={setAttachments}
              disabled={disabled}
            />
          )}
          <label className="flex items-center gap-1.5 text-xs text-muted-foreground cursor-pointer">
            <input
              type="checkbox"
              checked={isTask}
              onChange={(e) => {
                setIsTask(e.target.checked)
                if (!e.target.checked) setDueDate('')
              }}
              disabled={disabled}
            />
            {t('timeline.composer_task', 'És una tasca')}
          </label>
          {isTask && (
            <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <span>{t('timeline.composer_due_date', 'Venciment')}</span>
              <input
                type="date"
                value={dueDate}
                onChange={(e) => setDueDate(e.target.value)}
                disabled={disabled}
                className="h-8 rounded-md border border-input bg-background px-2 text-xs"
              />
            </label>
          )}
          {!isEdit && (
            <label className="flex items-center gap-1.5 text-xs text-muted-foreground cursor-pointer">
              <input
                type="checkbox"
                checked={isAiContextNote}
                onChange={(e) => setIsAiContextNote(e.target.checked)}
                disabled={disabled}
              />
              {t('timeline.composer_ai_note', 'Nota per a la IA')}
            </label>
          )}
        </div>
        <div className="flex items-center gap-2">
          {onCancel && (
            <Button type="button" variant="ghost" size="sm" onClick={onCancel} disabled={disabled}>
              {t('common:common.cancel', 'Cancel·lar')}
            </Button>
          )}
          <Button type="submit" size="sm" disabled={disabled || !canSubmit}>
            {submitLabel ?? t('timeline.composer_submit', 'Publicar')}
          </Button>
        </div>
      </div>
    </form>
  )
}

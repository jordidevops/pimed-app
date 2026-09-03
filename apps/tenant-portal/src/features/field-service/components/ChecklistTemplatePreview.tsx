import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Camera, MessageSquarePlus } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { ChecklistKindIcon } from './ChecklistKindIcon'
import type {
  ChecklistKind,
  ChecklistResponseOption,
  ChecklistResponseSet,
  ChecklistTemplateItem,
  DraftItemInput,
  ResponseType,
} from '../api/checklistTemplatesService'

export type PreviewItem = {
  key: string
  title: string
  description_internal?: string | null
  is_required?: boolean
  include_in_report?: boolean
  evidence_required?: boolean
  response_type?: ResponseType | null
  response_set_id?: string | null
}

type LocalAnswer = {
  valueBool: boolean | null
  valueOptionId: string | null
  note: string
}

const OPTION_TONES: Record<string, string> = {
  green: 'border-emerald-500 text-emerald-700 dark:text-emerald-400',
  yellow: 'border-amber-500 text-amber-700 dark:text-amber-400',
  orange: 'border-orange-500 text-orange-700 dark:text-orange-400',
  red: 'border-red-500 text-red-700 dark:text-red-400',
}

const OPTION_TONES_SELECTED: Record<string, string> = {
  green: 'border-emerald-500 bg-emerald-500/15 text-emerald-800 dark:text-emerald-300',
  yellow: 'border-amber-500 bg-amber-500/15 text-amber-800 dark:text-amber-300',
  orange: 'border-orange-500 bg-orange-500/15 text-orange-800 dark:text-orange-300',
  red: 'border-red-500 bg-red-500/15 text-red-800 dark:text-red-300',
}

function optionClasses(colorToken: string | null, selected: boolean): string {
  const token = colorToken ?? 'neutral'
  if (selected) {
    return OPTION_TONES_SELECTED[token] ?? 'border-primary bg-primary/10 text-foreground'
  }
  return OPTION_TONES[token] ?? 'border-border text-muted-foreground'
}

function emptyAnswer(): LocalAnswer {
  return { valueBool: null, valueOptionId: null, note: '' }
}

export function draftItemsToPreview(items: DraftItemInput[]): PreviewItem[] {
  return items
    .filter((i) => i.title.trim())
    .map((item, index) => ({
      key: `draft-${index}-${item.title.trim()}`,
      title: item.title.trim(),
      description_internal: item.description_internal,
      is_required: item.is_required === true,
      include_in_report: item.include_in_report === true,
      evidence_required: item.evidence_required === true,
      response_type: item.response_type ?? null,
      response_set_id: item.response_set_id ?? null,
    }))
}

export function templateItemsToPreview(items: ChecklistTemplateItem[]): PreviewItem[] {
  return items.map((item) => ({
    key: item.id,
    title: item.title,
    description_internal: item.description_internal,
    is_required: item.is_required,
    include_in_report: item.include_in_report,
    evidence_required: item.evidence_required,
    response_type: item.response_type,
    response_set_id: item.response_set_id,
  }))
}

function PreviewTodoItem({
  item,
  answer,
  onChange,
}: {
  item: PreviewItem
  answer: LocalAnswer
  onChange: (patch: Partial<LocalAnswer>) => void
}) {
  const { t } = useTranslation('field-service')
  const [noteOpen, setNoteOpen] = useState(Boolean(answer.note.trim()))
  const checked = answer.valueBool === true
  const hasNote = Boolean(answer.note.trim())

  return (
    <div className="space-y-1 px-1 py-0.5">
      <div className="flex min-h-10 items-center gap-2">
        <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-3 text-sm">
          <input
            type="checkbox"
            className="h-5 w-5 shrink-0 rounded border-border"
            checked={checked}
            onChange={(e) => onChange({ valueBool: e.target.checked })}
          />
          <span className={checked ? 'text-muted-foreground line-through' : ''}>
            {item.title}
            {item.is_required && <span className="ml-1 text-destructive">*</span>}
          </span>
        </label>
        {item.evidence_required && (
          <Camera className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
        )}
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className={`h-8 w-8 shrink-0 ${hasNote ? 'text-foreground' : 'text-muted-foreground'}`}
          onClick={() => setNoteOpen((v) => !v)}
          aria-expanded={noteOpen}
          aria-label={
            noteOpen
              ? t('runs.hide_note', 'Amagar nota')
              : hasNote
                ? t('runs.edit_note', 'Nota')
                : t('runs.add_note', 'Afegir nota')
          }
          title={
            noteOpen
              ? t('runs.hide_note', 'Amagar nota')
              : hasNote
                ? t('runs.edit_note', 'Nota')
                : t('runs.add_note', 'Afegir nota')
          }
        >
          <MessageSquarePlus className="h-4 w-4" />
        </Button>
      </div>
      {item.description_internal && (
        <p className="px-8 text-xs text-muted-foreground">{item.description_internal}</p>
      )}
      {noteOpen && (
        <div className="pl-8">
          <Textarea
            value={answer.note}
            rows={2}
            placeholder={t('runs.note_placeholder', 'Nota')}
            className="resize-none text-sm"
            onChange={(e) => onChange({ note: e.target.value })}
          />
        </div>
      )}
    </div>
  )
}

function PreviewReviewItem({
  item,
  options,
  answer,
  onChange,
}: {
  item: PreviewItem
  options: ChecklistResponseOption[]
  answer: LocalAnswer
  onChange: (patch: Partial<LocalAnswer>) => void
}) {
  const { t } = useTranslation('field-service')

  return (
    <div className="space-y-2 px-1 py-1">
      <div className="flex items-start gap-2">
        <p className="min-w-0 flex-1 text-sm font-medium">
          {item.title}
          {item.is_required && <span className="ml-1 text-destructive">*</span>}
        </p>
        {item.evidence_required && (
          <Camera className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
        )}
      </div>
      {item.description_internal && (
        <p className="text-xs text-muted-foreground">{item.description_internal}</p>
      )}
      {options.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {options.map((opt) => {
            const selected = answer.valueOptionId === opt.id
            return (
              <button
                key={opt.id}
                type="button"
                className={`rounded-md border px-2.5 py-1.5 text-xs font-medium transition-colors ${optionClasses(opt.color_token, selected)}`}
                onClick={() => onChange({ valueOptionId: selected ? null : opt.id })}
              >
                {opt.label}
              </button>
            )
          })}
        </div>
      ) : (
        <p className="text-xs text-muted-foreground">
          {t(
            'editor.preview_no_options',
            'Sense conjunt de respostes assignat (heretat o per ítem).',
          )}
        </p>
      )}
      <Textarea
        value={answer.note}
        rows={2}
        placeholder={t('runs.note_placeholder', 'Nota')}
        className="resize-none text-sm"
        onChange={(e) => onChange({ note: e.target.value })}
      />
    </div>
  )
}

/**
 * Interactive visit-like preview: checkboxes, options and notes work locally
 * and are never persisted.
 */
export function ChecklistTemplatePreview({
  kind,
  items,
  responseSets,
  defaultResponseSetId,
  emptyHint,
}: {
  kind: ChecklistKind
  items: PreviewItem[]
  responseSets: ChecklistResponseSet[]
  defaultResponseSetId?: string | null
  emptyHint?: string
}) {
  const { t } = useTranslation('field-service')
  const [answers, setAnswers] = useState<Record<string, LocalAnswer>>({})

  const itemKeys = useMemo(() => items.map((i) => i.key).join('|'), [items])

  // Reset ephemeral answers when the preview item set changes (edit → preview).
  useEffect(() => {
    setAnswers({})
  }, [itemKeys, kind, defaultResponseSetId])

  const optionsBySetId = useMemo(() => {
    const map = new Map<string, ChecklistResponseOption[]>()
    for (const set of responseSets) {
      if (set.options) map.set(set.id, set.options)
    }
    return map
  }, [responseSets])

  function patchAnswer(key: string, patch: Partial<LocalAnswer>) {
    setAnswers((prev) => ({
      ...prev,
      [key]: { ...(prev[key] ?? emptyAnswer()), ...patch },
    }))
  }

  if (items.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {emptyHint ?? t('editor.preview_empty', 'Afegeix ítems per veure la vista prèvia.')}
      </p>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
        <ChecklistKindIcon kind={kind} className="h-3.5 w-3.5" />
        <span>
          {t(
            'editor.preview_hint',
            'Pots provar respostes i notes aquí: no es desen enlloc.',
          )}
        </span>
        <Badge variant="outline" className="text-[10px] font-normal">
          {t('editor.preview_ephemeral', 'Sense desar')}
        </Badge>
      </div>

      <div className="rounded-lg border border-border p-3">
        <ul className={kind === 'todo' ? 'space-y-0.5' : 'space-y-2'}>
          {items.map((item) => {
            const setId = item.response_set_id ?? defaultResponseSetId ?? null
            const options = setId ? optionsBySetId.get(setId) ?? [] : []
            const isTodo = kind === 'todo' || item.response_type === 'checkbox'
            const answer = answers[item.key] ?? emptyAnswer()

            return (
              <li key={item.key}>
                {isTodo ? (
                  <PreviewTodoItem
                    item={item}
                    answer={answer}
                    onChange={(patch) => patchAnswer(item.key, patch)}
                  />
                ) : (
                  <PreviewReviewItem
                    item={item}
                    options={options}
                    answer={answer}
                    onChange={(patch) => patchAnswer(item.key, patch)}
                  />
                )}
              </li>
            )
          })}
        </ul>
      </div>
    </div>
  )
}

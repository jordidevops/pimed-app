'use client'

import { useEffect, useMemo, useState } from 'react'
import { Camera, MessageSquarePlus } from 'lucide-react'
import type { PlatformResponseSetOption } from '@/app/admin/actions/checklist-templates'
import { CHECKLIST_KIND_LABELS, type ChecklistKind } from '@/lib/platform-catalog/constants'

export type AdminPreviewItem = {
  key: string
  title: string
  description_internal?: string | null
  is_required?: boolean
  evidence_required?: boolean
  response_type?: string | null
  response_set_id?: string | null
}

type LocalAnswer = {
  valueBool: boolean | null
  valueOptionId: string | null
  note: string
}

type ResponseOption = NonNullable<PlatformResponseSetOption['options']>[number]

const OPTION_TONES: Record<string, string> = {
  green: 'border-emerald-500 text-emerald-700',
  yellow: 'border-amber-500 text-amber-700',
  orange: 'border-orange-500 text-orange-700',
  red: 'border-red-500 text-red-700',
}

const OPTION_TONES_SELECTED: Record<string, string> = {
  green: 'border-emerald-500 bg-emerald-50 text-emerald-800',
  yellow: 'border-amber-500 bg-amber-50 text-amber-800',
  orange: 'border-orange-500 bg-orange-50 text-orange-800',
  red: 'border-red-500 bg-red-50 text-red-800',
}

function optionClasses(colorToken: string | null, selected: boolean): string {
  const token = colorToken ?? 'neutral'
  if (selected) {
    return OPTION_TONES_SELECTED[token] ?? 'border-indigo-500 bg-indigo-50 text-indigo-900'
  }
  return OPTION_TONES[token] ?? 'border-gray-300 text-gray-600'
}

function emptyAnswer(): LocalAnswer {
  return { valueBool: null, valueOptionId: null, note: '' }
}

function PreviewTodoItem({
  item,
  answer,
  onChange,
}: {
  item: AdminPreviewItem
  answer: LocalAnswer
  onChange: (patch: Partial<LocalAnswer>) => void
}) {
  const [noteOpen, setNoteOpen] = useState(Boolean(answer.note.trim()))
  const checked = answer.valueBool === true
  const hasNote = Boolean(answer.note.trim())

  return (
    <div className="space-y-1 px-1 py-0.5">
      <div className="flex min-h-10 items-center gap-2">
        <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-3 text-sm">
          <input
            type="checkbox"
            className="h-5 w-5 shrink-0 rounded border-gray-300"
            checked={checked}
            onChange={(e) => onChange({ valueBool: e.target.checked })}
          />
          <span className={checked ? 'text-gray-400 line-through' : 'text-gray-900'}>
            {item.title}
            {item.is_required && <span className="ml-1 text-red-600">*</span>}
          </span>
        </label>
        {item.evidence_required && (
          <Camera className="h-4 w-4 shrink-0 text-gray-400" aria-hidden />
        )}
        <button
          type="button"
          className={`inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md hover:bg-gray-100 ${
            hasNote ? 'text-gray-800' : 'text-gray-400'
          }`}
          onClick={() => setNoteOpen((v) => !v)}
          aria-expanded={noteOpen}
          title={noteOpen ? 'Amagar nota' : hasNote ? 'Nota' : 'Afegir nota'}
        >
          <MessageSquarePlus className="h-4 w-4" />
        </button>
      </div>
      {item.description_internal && (
        <p className="px-8 text-xs text-gray-500">{item.description_internal}</p>
      )}
      {noteOpen && (
        <div className="pl-8">
          <textarea
            value={answer.note}
            rows={2}
            placeholder="Nota"
            className="w-full resize-none rounded-md border border-gray-200 px-2 py-1.5 text-sm"
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
  item: AdminPreviewItem
  options: ResponseOption[]
  answer: LocalAnswer
  onChange: (patch: Partial<LocalAnswer>) => void
}) {
  return (
    <div className="space-y-2 px-1 py-1">
      <div className="flex items-start gap-2">
        <p className="min-w-0 flex-1 text-sm font-medium text-gray-900">
          {item.title}
          {item.is_required && <span className="ml-1 text-red-600">*</span>}
        </p>
        {item.evidence_required && (
          <Camera className="mt-0.5 h-4 w-4 shrink-0 text-gray-400" aria-hidden />
        )}
      </div>
      {item.description_internal && (
        <p className="text-xs text-gray-500">{item.description_internal}</p>
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
        <p className="text-xs text-gray-500">
          Sense conjunt de respostes assignat (heretat o per ítem).
        </p>
      )}
      <textarea
        value={answer.note}
        rows={2}
        placeholder="Nota"
        className="w-full resize-none rounded-md border border-gray-200 px-2 py-1.5 text-sm"
        onChange={(e) => onChange({ note: e.target.value })}
      />
    </div>
  )
}

/**
 * Interactive visit-like preview for platform templates.
 * Answers stay local and are never persisted.
 */
export function PlatformChecklistTemplatePreview({
  kind,
  items,
  responseSets,
  defaultResponseSetId,
  emptyHint,
}: {
  kind: ChecklistKind | string
  items: AdminPreviewItem[]
  responseSets: PlatformResponseSetOption[]
  defaultResponseSetId?: string | null
  emptyHint?: string
}) {
  const [answers, setAnswers] = useState<Record<string, LocalAnswer>>({})
  const itemKeys = useMemo(() => items.map((i) => i.key).join('|'), [items])

  useEffect(() => {
    setAnswers({})
  }, [itemKeys, kind, defaultResponseSetId])

  const optionsBySetId = useMemo(() => {
    const map = new Map<string, ResponseOption[]>()
    for (const set of responseSets) {
      map.set(set.id, set.options ?? [])
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
      <p className="text-sm text-gray-500">
        {emptyHint ?? 'Afegeix ítems per veure la vista prèvia.'}
      </p>
    )
  }

  const kindLabel =
    CHECKLIST_KIND_LABELS[kind as ChecklistKind] ?? String(kind)

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500">
        <span className="rounded-full bg-gray-100 px-2 py-0.5 font-medium text-gray-700">
          {kindLabel}
        </span>
        <span>Pots provar respostes i notes aquí: no es desen enlloc.</span>
        <span className="rounded-full border border-gray-200 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-gray-500">
          Sense desar
        </span>
      </div>

      <div className="rounded-xl border border-gray-200 bg-white p-3">
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

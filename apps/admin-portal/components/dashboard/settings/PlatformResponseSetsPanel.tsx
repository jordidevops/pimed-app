'use client'

import { useCallback, useEffect, useState, useTransition } from 'react'
import {
  createPlatformResponseSet,
  listPlatformResponseSetsAdmin,
  setPlatformResponseSetActive,
  updatePlatformResponseSet,
  type PlatformResponseSet,
  type ResponseOptionInput,
  type ResponseSetInput,
} from '@/app/admin/actions/checklist-response-sets'
import {
  CHECKLIST_ANSWER_SEMANTIC_HINTS,
  CHECKLIST_ANSWER_SEMANTIC_LABELS,
  CHECKLIST_ANSWER_SEMANTICS,
  CHECKLIST_COLOR_TOKENS,
  CHECKLIST_LOCALES,
  CHECKLIST_LOCALE_LABELS,
  type ChecklistAnswerSemantic,
  type ChecklistLocale,
  type PagedResult,
} from '@/lib/platform-catalog/constants'
import {
  Banner,
  Chip,
  EmptyRow,
  Field,
  Pager,
  dangerButtonClass,
  inputClass,
  primaryButtonClass,
  secondaryButtonClass,
} from './CatalogControls'

interface Props {
  initial: PagedResult<PlatformResponseSet>
  canEdit: boolean
}

interface OptionForm {
  key: string
  id: string | null
  label: string
  semantics: ChecklistAnswerSemantic
  blocks_closeout: boolean
  requires_note: boolean
  color_token: string
  locked: boolean
}

interface FormState {
  name: string
  code: string
  locale: ChecklistLocale
  category: string
  vertical: string
  is_active: boolean
  options: OptionForm[]
  published_locked: boolean
}

let optionSeq = 0
function nextOptionKey() {
  optionSeq += 1
  return `opt-${optionSeq}`
}

function emptyOption(): OptionForm {
  return {
    key: nextOptionKey(),
    id: null,
    label: '',
    semantics: 'pass',
    blocks_closeout: false,
    requires_note: false,
    color_token: 'green',
    locked: false,
  }
}

function emptyForm(): FormState {
  return {
    name: '',
    code: '',
    locale: 'ca',
    category: 'general',
    vertical: 'generic',
    is_active: true,
    options: [
      { ...emptyOption(), label: 'Conforme', semantics: 'pass', color_token: 'green' },
      {
        ...emptyOption(),
        label: 'No conforme',
        semantics: 'fail',
        blocks_closeout: true,
        requires_note: true,
        color_token: 'red',
      },
    ],
    published_locked: false,
  }
}

function formFromSet(set: PlatformResponseSet): FormState {
  return {
    name: set.name,
    code: set.code ?? '',
    locale: set.locale as ChecklistLocale,
    category: set.category,
    vertical: set.vertical,
    is_active: set.is_active,
    published_locked: set.published_locked,
    options: set.options.map((opt) => ({
      key: opt.id,
      id: opt.id,
      label: opt.label,
      semantics: opt.semantics,
      blocks_closeout: opt.blocks_closeout,
      requires_note: opt.requires_note,
      color_token: opt.color_token ?? 'neutral',
      locked: opt.locked || set.published_locked,
    })),
  }
}

function toInput(form: FormState): ResponseSetInput {
  return {
    name: form.name,
    code: form.code,
    locale: form.locale,
    category: form.category,
    vertical: form.vertical,
    is_active: form.is_active,
    options: form.options.map(
      (opt, index): ResponseOptionInput => ({
        id: opt.id,
        label: opt.label,
        semantics: opt.semantics,
        position: index,
        blocks_closeout: opt.blocks_closeout,
        requires_note: opt.requires_note,
        color_token: opt.color_token || null,
      }),
    ),
  }
}

export function PlatformResponseSetsPanel({ initial, canEdit }: Props) {
  const [data, setData] = useState(initial)
  const [isPending, startTransition] = useTransition()
  const [feedback, setFeedback] = useState<{ tone: 'success' | 'error'; message: string } | null>(
    null,
  )

  const [search, setSearch] = useState('')
  const [locale, setLocale] = useState('')
  const [includeInactive, setIncludeInactive] = useState(false)

  const [editingId, setEditingId] = useState<string | null>(null)
  const [form, setForm] = useState<FormState>(emptyForm())
  const [formOpen, setFormOpen] = useState(false)

  const reload = useCallback(
    (nextPage = 1) => {
      startTransition(async () => {
        try {
          const result = await listPlatformResponseSetsAdmin({
            search,
            locale: locale || undefined,
            includeArchived: includeInactive,
            page: nextPage,
          })
          setData(result)
        } catch (err) {
          setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
        }
      })
    },
    [search, locale, includeInactive],
  )

  useEffect(() => {
    const handle = setTimeout(() => reload(1), 300)
    return () => clearTimeout(handle)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search, locale, includeInactive])

  function openCreate() {
    setEditingId(null)
    setForm(emptyForm())
    setFormOpen(true)
  }

  function openEdit(set: PlatformResponseSet) {
    setEditingId(set.id)
    setForm(formFromSet(set))
    setFormOpen(true)
  }

  function runAction(action: () => Promise<{ ok: boolean; message: string }>) {
    startTransition(async () => {
      try {
        const result = await action()
        setFeedback({ tone: result.ok ? 'success' : 'error', message: result.message })
        if (result.ok) {
          setFormOpen(false)
          reload(data.page)
        }
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }

  function updateOption(index: number, patch: Partial<OptionForm>) {
    setForm((prev) => ({
      ...prev,
      options: prev.options.map((opt, i) => (i === index ? { ...opt, ...patch } : opt)),
    }))
  }

  return (
    <div className="space-y-4">
      {feedback && <Banner tone={feedback.tone}>{feedback.message}</Banner>}

      <div className="flex flex-wrap items-end gap-3 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm">
        <Field label="Cerca" className="min-w-56 flex-1">
          <input
            className={inputClass}
            value={search}
            placeholder="Nom o codi"
            onChange={(e) => setSearch(e.target.value)}
          />
        </Field>
        <Field label="Idioma">
          <select className={inputClass} value={locale} onChange={(e) => setLocale(e.target.value)}>
            <option value="">Tots</option>
            {CHECKLIST_LOCALES.map((code) => (
              <option key={code} value={code}>
                {CHECKLIST_LOCALE_LABELS[code]}
              </option>
            ))}
          </select>
        </Field>
        <label className="flex items-center gap-2 pb-2 text-sm text-gray-700">
          <input
            type="checkbox"
            checked={includeInactive}
            onChange={(e) => setIncludeInactive(e.target.checked)}
          />
          Incloure inactius
        </label>
        {canEdit && (
          <button type="button" className={primaryButtonClass} onClick={openCreate} disabled={isPending}>
            Nou conjunt
          </button>
        )}
      </div>

      <p className="rounded-lg border border-indigo-100 bg-indigo-50/60 px-3 py-2 text-xs text-indigo-900">
        La semàntica <strong>fail</strong> bloqueja avui el tancament de la visita. Les opcions ja
        usades en respostes o plantilles publicades queden bloquejades (no es poden canviar ni
        esborrar).
      </p>

      <section className="overflow-hidden rounded-2xl border border-gray-100 bg-white shadow-sm">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Nom</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Opcions</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Taxonomia</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Estat</th>
                <th className="px-4 py-3 text-right font-medium text-gray-700">Accions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {data.rows.length === 0 ? (
                <EmptyRow colSpan={5}>Cap conjunt amb aquests filtres.</EmptyRow>
              ) : (
                data.rows.map((set) => (
                  <tr key={set.id} className={!set.is_active ? 'opacity-60' : undefined}>
                    <td className="px-4 py-3">
                      <p className="font-medium text-gray-900">{set.name}</p>
                      {set.code && <p className="text-xs text-gray-500">{set.code}</p>}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex flex-wrap gap-1">
                        {set.options.map((opt) => (
                          <Chip key={opt.id} tone={opt.semantics === 'fail' ? 'amber' : undefined}>
                            {opt.label}
                          </Chip>
                        ))}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex flex-wrap gap-1">
                        <Chip>{CHECKLIST_LOCALE_LABELS[set.locale as ChecklistLocale] ?? set.locale}</Chip>
                        <Chip>{set.category}</Chip>
                        <Chip>{set.vertical}</Chip>
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      {set.is_active ? <Chip tone="green">Actiu</Chip> : <Chip>Inactiu</Chip>}
                      {set.published_locked && <Chip tone="indigo">En ús publicat</Chip>}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex justify-end gap-2">
                        <button
                          type="button"
                          className={secondaryButtonClass}
                          onClick={() => openEdit(set)}
                          disabled={isPending}
                        >
                          {canEdit ? 'Editar' : 'Veure'}
                        </button>
                        {canEdit && (
                          <button
                            type="button"
                            className={set.is_active ? dangerButtonClass : secondaryButtonClass}
                            onClick={() =>
                              runAction(() => setPlatformResponseSetActive(set.id, !set.is_active))
                            }
                            disabled={isPending}
                          >
                            {set.is_active ? 'Desactivar' : 'Activar'}
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
        <Pager
          page={data.page}
          pageCount={data.pageCount}
          total={data.total}
          disabled={isPending}
          onChange={(nextPage) => reload(nextPage)}
        />
      </section>

      {formOpen && (
        <section className="space-y-4 rounded-2xl border border-indigo-100 bg-white p-4 shadow-sm">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold text-gray-900">
                {editingId ? 'Editar conjunt' : 'Nou conjunt'}
              </h2>
              {form.published_locked && (
                <p className="mt-1 text-xs text-amber-700">
                  Usat en plantilles publicades: les opcions existents són immutables; pots afegir-ne
                  de noves o desactivar el conjunt.
                </p>
              )}
            </div>
            <button type="button" className={secondaryButtonClass} onClick={() => setFormOpen(false)}>
              Tancar
            </button>
          </div>

          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <Field label="Nom" className="sm:col-span-2">
              <input
                className={inputClass}
                value={form.name}
                disabled={!canEdit}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
              />
            </Field>
            <Field label="Codi" hint="Opcional, únic a plataforma">
              <input
                className={inputClass}
                value={form.code}
                disabled={!canEdit}
                onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))}
              />
            </Field>
            <Field label="Idioma">
              <select
                className={inputClass}
                value={form.locale}
                disabled={!canEdit}
                onChange={(e) =>
                  setForm((f) => ({ ...f, locale: e.target.value as ChecklistLocale }))
                }
              >
                {CHECKLIST_LOCALES.map((code) => (
                  <option key={code} value={code}>
                    {CHECKLIST_LOCALE_LABELS[code]}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Categoria">
              <input
                className={inputClass}
                value={form.category}
                disabled={!canEdit}
                onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
              />
            </Field>
            <Field label="Vertical">
              <input
                className={inputClass}
                value={form.vertical}
                disabled={!canEdit}
                onChange={(e) => setForm((f) => ({ ...f, vertical: e.target.value }))}
              />
            </Field>
            <label className="flex items-end gap-2 pb-2 text-sm text-gray-700">
              <input
                type="checkbox"
                checked={form.is_active}
                disabled={!canEdit}
                onChange={(e) => setForm((f) => ({ ...f, is_active: e.target.checked }))}
              />
              Actiu
            </label>
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between gap-2">
              <h3 className="text-sm font-semibold text-gray-900">Opcions</h3>
              {canEdit && (
                <button
                  type="button"
                  className={secondaryButtonClass}
                  onClick={() =>
                    setForm((f) => ({ ...f, options: [...f.options, emptyOption()] }))
                  }
                >
                  Afegir opció
                </button>
              )}
            </div>

            {form.options.map((opt, index) => (
              <div
                key={opt.key}
                className="grid gap-2 rounded-xl border border-gray-100 bg-gray-50/70 p-3 lg:grid-cols-[1fr,1fr,1fr,auto]"
              >
                <Field label={`Etiqueta ${index + 1}`}>
                  <input
                    className={inputClass}
                    value={opt.label}
                    disabled={!canEdit || opt.locked}
                    onChange={(e) => updateOption(index, { label: e.target.value })}
                  />
                </Field>
                <Field
                  label="Semàntica"
                  hint={CHECKLIST_ANSWER_SEMANTIC_HINTS[opt.semantics]}
                >
                  <select
                    className={inputClass}
                    value={opt.semantics}
                    disabled={!canEdit || opt.locked}
                    onChange={(e) =>
                      updateOption(index, {
                        semantics: e.target.value as ChecklistAnswerSemantic,
                      })
                    }
                  >
                    {CHECKLIST_ANSWER_SEMANTICS.map((code) => (
                      <option key={code} value={code}>
                        {CHECKLIST_ANSWER_SEMANTIC_LABELS[code]}
                      </option>
                    ))}
                  </select>
                </Field>
                <Field label="Color">
                  <select
                    className={inputClass}
                    value={opt.color_token}
                    disabled={!canEdit || opt.locked}
                    onChange={(e) => updateOption(index, { color_token: e.target.value })}
                  >
                    {CHECKLIST_COLOR_TOKENS.map((token) => (
                      <option key={token} value={token}>
                        {token}
                      </option>
                    ))}
                  </select>
                </Field>
                <div className="flex flex-wrap items-end gap-3 pb-1 text-xs text-gray-700">
                  <label className="flex items-center gap-1.5">
                    <input
                      type="checkbox"
                      checked={opt.blocks_closeout}
                      disabled={!canEdit || opt.locked}
                      onChange={(e) => updateOption(index, { blocks_closeout: e.target.checked })}
                    />
                    Bloqueja closeout
                  </label>
                  <label className="flex items-center gap-1.5">
                    <input
                      type="checkbox"
                      checked={opt.requires_note}
                      disabled={!canEdit || opt.locked}
                      onChange={(e) => updateOption(index, { requires_note: e.target.checked })}
                    />
                    Requereix nota
                  </label>
                  {opt.locked && <Chip tone="amber">Bloquejada</Chip>}
                  {canEdit && !opt.locked && form.options.length > 1 && (
                    <button
                      type="button"
                      className={dangerButtonClass}
                      onClick={() =>
                        setForm((f) => ({
                          ...f,
                          options: f.options.filter((_, i) => i !== index),
                        }))
                      }
                    >
                      Treure
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>

          {canEdit && (
            <div className="flex justify-end gap-2">
              <button type="button" className={secondaryButtonClass} onClick={() => setFormOpen(false)}>
                Cancel·lar
              </button>
              <button
                type="button"
                className={primaryButtonClass}
                disabled={isPending}
                onClick={() =>
                  runAction(() =>
                    editingId
                      ? updatePlatformResponseSet(editingId, toInput(form))
                      : createPlatformResponseSet(toInput(form)),
                  )
                }
              >
                Desar
              </button>
            </div>
          )}
        </section>
      )}
    </div>
  )
}

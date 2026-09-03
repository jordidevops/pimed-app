'use client'

import { useCallback, useEffect, useState, useTransition } from 'react'
import {
  createPlatformReviewPoint,
  deletePlatformReviewPoint,
  listPlatformReviewPoints,
  setPlatformReviewPointActive,
  updatePlatformReviewPoint,
  type PlatformReviewPoint,
  type ReviewPointFacets,
  type ReviewPointInput,
} from '@/app/admin/actions/checklist-points'
import {
  CHECKLIST_ARCHETYPES,
  CHECKLIST_ARCHETYPE_LABELS,
  CHECKLIST_LOCALES,
  CHECKLIST_LOCALE_LABELS,
  type ChecklistArchetype,
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
  initial: PagedResult<PlatformReviewPoint>
  facets: ReviewPointFacets
  canEdit: boolean
}

interface FormState {
  title: string
  description: string
  client_text: string
  locale: ChecklistLocale
  category: string
  vertical: string
  archetype: ChecklistArchetype
  is_active: boolean
}

function emptyForm(): FormState {
  return {
    title: '',
    description: '',
    client_text: '',
    locale: 'ca',
    category: 'general',
    vertical: 'generic',
    archetype: 'field_service',
    is_active: true,
  }
}

function formFromPoint(point: PlatformReviewPoint): FormState {
  return {
    title: point.title,
    description: point.description ?? '',
    client_text: point.client_text ?? '',
    locale: point.locale as ChecklistLocale,
    category: point.category,
    vertical: point.vertical,
    archetype: point.archetype as ChecklistArchetype,
    is_active: point.is_active,
  }
}

function toInput(form: FormState): ReviewPointInput {
  return {
    title: form.title,
    description: form.description,
    client_text: form.client_text,
    locale: form.locale,
    category: form.category,
    vertical: form.vertical,
    archetype: form.archetype,
    is_active: form.is_active,
  }
}

export function PlatformReviewPointsPanel({ initial, facets, canEdit }: Props) {
  const [data, setData] = useState(initial)
  const [isPending, startTransition] = useTransition()
  const [feedback, setFeedback] = useState<{ tone: 'success' | 'error'; message: string } | null>(null)

  const [search, setSearch] = useState('')
  const [locale, setLocale] = useState('')
  const [category, setCategory] = useState('')
  const [vertical, setVertical] = useState('')
  const [archetype, setArchetype] = useState('')
  const [includeArchived, setIncludeArchived] = useState(false)

  const [editingId, setEditingId] = useState<string | null>(null)
  const [form, setForm] = useState<FormState>(emptyForm())
  const [formOpen, setFormOpen] = useState(false)

  const reload = useCallback(
    (nextPage = 1) => {
      startTransition(async () => {
        try {
          const result = await listPlatformReviewPoints({
            search,
            locale: locale || undefined,
            category: category || undefined,
            vertical: vertical || undefined,
            archetype: archetype || undefined,
            includeArchived,
            page: nextPage,
          })
          setData(result)
        } catch (err) {
          setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
        }
      })
    },
    [search, locale, category, vertical, archetype, includeArchived],
  )

  // Debounced so typing in the search box doesn't fire a request per keystroke.
  useEffect(() => {
    const handle = setTimeout(() => reload(1), 300)
    return () => clearTimeout(handle)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search, locale, category, vertical, archetype, includeArchived])

  function openCreate() {
    setEditingId(null)
    setForm(emptyForm())
    setFormOpen(true)
  }

  function openEdit(point: PlatformReviewPoint) {
    setEditingId(point.id)
    setForm(formFromPoint(point))
    setFormOpen(true)
  }

  function runAction(action: () => Promise<{ ok: boolean; message: string }>) {
    startTransition(async () => {
      try {
        const result = await action()
        setFeedback({ tone: result.ok ? 'success' : 'error', message: result.message })
        if (result.ok) {
          setFormOpen(false)
          setEditingId(null)
          reload(data.page)
        }
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }

  function handleSubmit() {
    if (!form.title.trim()) {
      setFeedback({ tone: 'error', message: 'El títol del punt és obligatori.' })
      return
    }
    runAction(() =>
      editingId
        ? updatePlatformReviewPoint(editingId, toInput(form))
        : createPlatformReviewPoint(toInput(form)),
    )
  }

  return (
    <div className="space-y-4">
      {feedback && (
        <Banner tone={feedback.tone} message={feedback.message} onDismiss={() => setFeedback(null)} />
      )}

      <section className="space-y-3 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <Field label="Cercar" className="lg:col-span-2">
            <input
              className={inputClass}
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Títol o descripció"
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
          <Field label="Categoria">
            <select
              className={inputClass}
              value={category}
              onChange={(e) => setCategory(e.target.value)}
            >
              <option value="">Totes</option>
              {facets.categories.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Vertical">
            <select
              className={inputClass}
              value={vertical}
              onChange={(e) => setVertical(e.target.value)}
            >
              <option value="">Totes</option>
              {facets.verticals.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </select>
          </Field>
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex flex-wrap items-center gap-4">
            <label className="flex items-center gap-2 text-sm text-gray-700">
              <span className="font-medium">Arquetip</span>
              <select
                className={inputClass}
                value={archetype}
                onChange={(e) => setArchetype(e.target.value)}
              >
                <option value="">Tots</option>
                {CHECKLIST_ARCHETYPES.map((code) => (
                  <option key={code} value={code}>
                    {CHECKLIST_ARCHETYPE_LABELS[code]}
                  </option>
                ))}
              </select>
            </label>
            <label className="flex items-center gap-2 text-sm text-gray-700">
              <input
                type="checkbox"
                checked={includeArchived}
                onChange={(e) => setIncludeArchived(e.target.checked)}
              />
              Incloure arxivats
            </label>
          </div>

          {canEdit && (
            <button type="button" className={primaryButtonClass} onClick={openCreate} disabled={isPending}>
              + Nou punt
            </button>
          )}
        </div>
      </section>

      {formOpen && canEdit && (
        <section className="space-y-3 rounded-2xl border border-indigo-100 bg-white p-4 shadow-sm">
          <h2 className="text-base font-semibold text-gray-900">
            {editingId ? 'Editar punt de revisió' : 'Nou punt de revisió'}
          </h2>

          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Títol" className="sm:col-span-2">
              <input
                className={inputClass}
                value={form.title}
                onChange={(e) => setForm((f) => ({ ...f, title: e.target.value }))}
                placeholder="Ex: Pressió del circuit"
              />
            </Field>
            <Field
              label="Descripció interna"
              hint="Instruccions per al tècnic. No surt al part del client."
              className="sm:col-span-2"
            >
              <textarea
                className={inputClass}
                rows={2}
                value={form.description}
                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
              />
            </Field>
            <Field
              label="Text per al client"
              hint="Text que apareix al part públic si el punt s'inclou a l'informe."
              className="sm:col-span-2"
            >
              <textarea
                className={inputClass}
                rows={2}
                value={form.client_text}
                onChange={(e) => setForm((f) => ({ ...f, client_text: e.target.value }))}
              />
            </Field>
            <Field label="Idioma">
              <select
                className={inputClass}
                value={form.locale}
                onChange={(e) => setForm((f) => ({ ...f, locale: e.target.value as ChecklistLocale }))}
              >
                {CHECKLIST_LOCALES.map((code) => (
                  <option key={code} value={code}>
                    {CHECKLIST_LOCALE_LABELS[code]}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Arquetip">
              <select
                className={inputClass}
                value={form.archetype}
                onChange={(e) =>
                  setForm((f) => ({ ...f, archetype: e.target.value as ChecklistArchetype }))
                }
              >
                {CHECKLIST_ARCHETYPES.map((code) => (
                  <option key={code} value={code}>
                    {CHECKLIST_ARCHETYPE_LABELS[code]}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Categoria" hint="Es normalitza a minúscules (ex: caldera).">
              <input
                className={inputClass}
                value={form.category}
                onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
              />
            </Field>
            <Field label="Vertical" hint="Ex: plumbing, vending, qsr_kitchen.">
              <input
                className={inputClass}
                value={form.vertical}
                onChange={(e) => setForm((f) => ({ ...f, vertical: e.target.value }))}
              />
            </Field>
          </div>

          <label className="flex items-center gap-2 text-sm text-gray-700">
            <input
              type="checkbox"
              checked={form.is_active}
              onChange={(e) => setForm((f) => ({ ...f, is_active: e.target.checked }))}
            />
            Actiu (visible per als tenants)
          </label>

          <div className="flex gap-2">
            <button type="button" className={primaryButtonClass} onClick={handleSubmit} disabled={isPending}>
              {isPending ? 'Desant…' : 'Desar'}
            </button>
            <button
              type="button"
              className={secondaryButtonClass}
              onClick={() => {
                setFormOpen(false)
                setEditingId(null)
              }}
              disabled={isPending}
            >
              Cancel·lar
            </button>
          </div>
        </section>
      )}

      <section className="space-y-3">
        <div className="overflow-x-auto rounded-lg border border-gray-200 bg-white">
          <table className="min-w-full divide-y divide-gray-200 text-sm">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Títol</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Taxonomia</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Idioma</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Ús</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Estat</th>
                {canEdit && <th className="px-4 py-3 text-right font-medium text-gray-700">Accions</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {data.rows.length === 0 ? (
                <EmptyRow colSpan={canEdit ? 6 : 5}>
                  Cap punt de revisió de plataforma amb aquests filtres.
                </EmptyRow>
              ) : (
                data.rows.map((point) => (
                  <tr key={point.id} className={point.is_archived ? 'opacity-60' : undefined}>
                    <td className="px-4 py-3">
                      <p className="font-medium text-gray-900">{point.title}</p>
                      {point.description && (
                        <p className="mt-0.5 max-w-xl text-xs text-gray-500">{point.description}</p>
                      )}
                    </td>
                    <td className="px-4 py-3 text-gray-600">
                      <div className="flex flex-wrap gap-1">
                        <Chip>{point.category}</Chip>
                        <Chip>{point.vertical}</Chip>
                        <Chip tone="indigo">
                          {CHECKLIST_ARCHETYPE_LABELS[point.archetype as ChecklistArchetype] ??
                            point.archetype}
                        </Chip>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-gray-600">
                      {CHECKLIST_LOCALE_LABELS[point.locale as ChecklistLocale] ?? point.locale}
                      <span className="ml-1 text-xs text-gray-400">v{point.catalog_version}</span>
                    </td>
                    <td className="px-4 py-3 text-gray-600 tabular-nums">{point.usage_count ?? 0}</td>
                    <td className="px-4 py-3">
                      {point.is_archived ? (
                        <Chip tone="amber">Arxivat</Chip>
                      ) : point.is_active ? (
                        <Chip tone="green">Actiu</Chip>
                      ) : (
                        <Chip>Inactiu</Chip>
                      )}
                    </td>
                    {canEdit && (
                      <td className="px-4 py-3">
                        <div className="flex justify-end gap-2">
                          <button
                            type="button"
                            className={secondaryButtonClass}
                            onClick={() => openEdit(point)}
                            disabled={isPending}
                          >
                            Editar
                          </button>
                          <button
                            type="button"
                            className={secondaryButtonClass}
                            onClick={() =>
                              runAction(() =>
                                setPlatformReviewPointActive(point.id, !point.is_active),
                              )
                            }
                            disabled={isPending || point.is_archived}
                          >
                            {point.is_active ? 'Desactivar' : 'Activar'}
                          </button>
                          <button
                            type="button"
                            className={dangerButtonClass}
                            onClick={() => runAction(() => deletePlatformReviewPoint(point.id))}
                            disabled={isPending}
                          >
                            Esborrar
                          </button>
                        </div>
                      </td>
                    )}
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
    </div>
  )
}

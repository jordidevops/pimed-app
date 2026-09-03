'use client'

import { useCallback, useEffect, useMemo, useState, useTransition } from 'react'
import { Eye } from 'lucide-react'
import {
  listPlatformReviewPointOptions,
  type PlatformReviewPoint,
} from '@/app/admin/actions/checklist-points'
import {
  archivePlatformChecklistTemplate,
  createPlatformChecklistTemplate,
  createPlatformTemplateDraft,
  getPlatformChecklistTemplate,
  listPlatformChecklistTemplates,
  publishPlatformTemplateVersion,
  savePlatformTemplateDraftItems,
  setPlatformTemplateActive,
  setPlatformTemplateDefaultResponseSet,
  updatePlatformChecklistTemplate,
  type DraftItemInput,
  type PlatformChecklistTemplate,
  type PlatformResponseSetOption,
  type PlatformTemplateDetail,
  type TemplateInput,
} from '@/app/admin/actions/checklist-templates'
import {
  CHECKLIST_ARCHETYPES,
  CHECKLIST_ARCHETYPE_LABELS,
  CHECKLIST_KINDS,
  CHECKLIST_KIND_LABELS,
  CHECKLIST_LOCALES,
  CHECKLIST_LOCALE_LABELS,
  type ChecklistArchetype,
  type ChecklistKind,
  type ChecklistLocale,
  type PagedResult,
} from '@/lib/platform-catalog/constants'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  PlatformChecklistTemplatePreview,
  type AdminPreviewItem,
} from './PlatformChecklistTemplatePreview'
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
  initial: PagedResult<PlatformChecklistTemplate>
  responseSets: PlatformResponseSetOption[]
  canEdit: boolean
}

interface MetaForm {
  name: string
  description: string
  kind: ChecklistKind
  locale: ChecklistLocale
  category: string
  vertical: string
  archetype: ChecklistArchetype
  is_active: boolean
}

interface DraftRow {
  key: string
  review_point_id: string | null
  title: string
  description_internal: string
  description_public: string
  include_in_report: boolean
  is_required: boolean
  evidence_required: boolean
}

function emptyMeta(): MetaForm {
  return {
    name: '',
    description: '',
    kind: 'review',
    locale: 'ca',
    category: 'general',
    vertical: 'generic',
    archetype: 'field_service',
    is_active: true,
  }
}

function metaFromTemplate(template: PlatformChecklistTemplate): MetaForm {
  return {
    name: template.name,
    description: template.description ?? '',
    kind: template.kind as ChecklistKind,
    locale: template.locale as ChecklistLocale,
    category: template.category,
    vertical: template.vertical,
    archetype: template.archetype as ChecklistArchetype,
    is_active: template.is_active,
  }
}

function toTemplateInput(meta: MetaForm): TemplateInput {
  return {
    name: meta.name,
    description: meta.description,
    kind: meta.kind,
    locale: meta.locale,
    category: meta.category,
    vertical: meta.vertical,
    archetype: meta.archetype,
    is_active: meta.is_active,
  }
}

function rowsFromDetail(detail: PlatformTemplateDetail): DraftRow[] {
  return detail.items.map((item, index) => ({
    key: `${item.id}-${index}`,
    review_point_id: item.review_point_id,
    title: item.title,
    description_internal: item.description_internal ?? '',
    description_public: item.description_public ?? '',
    include_in_report: item.include_in_report,
    is_required: item.is_required,
    evidence_required: item.evidence_required,
  }))
}

let rowSeq = 0
function nextKey() {
  rowSeq += 1
  return `new-${rowSeq}`
}

export function PlatformChecklistTemplatesPanel({ initial, responseSets, canEdit }: Props) {
  const [data, setData] = useState(initial)
  const [isPending, startTransition] = useTransition()
  const [feedback, setFeedback] = useState<{ tone: 'success' | 'error'; message: string } | null>(null)

  const [search, setSearch] = useState('')
  const [kind, setKind] = useState('')
  const [locale, setLocale] = useState('')
  const [archetype, setArchetype] = useState('')
  const [includeArchived, setIncludeArchived] = useState(false)

  const [creating, setCreating] = useState(false)
  const [createMeta, setCreateMeta] = useState<MetaForm>(emptyMeta())

  const [detail, setDetail] = useState<PlatformTemplateDetail | null>(null)
  const [meta, setMeta] = useState<MetaForm>(emptyMeta())
  const [rows, setRows] = useState<DraftRow[]>([])
  const [defaultSetId, setDefaultSetId] = useState('')
  const [points, setPoints] = useState<PlatformReviewPoint[]>([])
  const [pointToAdd, setPointToAdd] = useState('')
  const [editorTab, setEditorTab] = useState<'edit' | 'preview'>('edit')
  const [listPreview, setListPreview] = useState<{
    name: string
    kind: string
    items: AdminPreviewItem[]
    defaultResponseSetId: string | null
  } | null>(null)

  const reload = useCallback(
    (nextPage = 1) => {
      startTransition(async () => {
        try {
          const result = await listPlatformChecklistTemplates({
            search,
            kind: kind || undefined,
            locale: locale || undefined,
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
    [search, kind, locale, archetype, includeArchived],
  )

  useEffect(() => {
    const handle = setTimeout(() => reload(1), 300)
    return () => clearTimeout(handle)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search, kind, locale, archetype, includeArchived])

  const loadDetail = useCallback((templateId: string) => {
    startTransition(async () => {
      try {
        const result = await getPlatformChecklistTemplate(templateId)
        setDetail(result)
        setMeta(metaFromTemplate(result.template))
        setRows(rowsFromDetail(result))
        setDefaultSetId(result.editingVersion?.default_response_set_id ?? '')
        setPointToAdd('')
        setEditorTab('edit')

        const options = await listPlatformReviewPointOptions({ locale: result.template.locale })
        setPoints(options)
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }, [])

  const openListPreview = useCallback((templateId: string) => {
    startTransition(async () => {
      try {
        const result = await getPlatformChecklistTemplate(templateId)
        setListPreview({
          name: result.template.name,
          kind: result.template.kind,
          items: result.items.map((item) => ({
            key: item.id,
            title: item.title,
            description_internal: item.description_internal,
            is_required: item.is_required,
            evidence_required: item.evidence_required,
            response_type: item.response_type,
            response_set_id: item.response_set_id,
          })),
          defaultResponseSetId: result.editingVersion?.default_response_set_id ?? null,
        })
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }, [])

  const previewItemsFromDraft = useMemo<AdminPreviewItem[]>(
    () =>
      rows
        .filter((row) => row.title.trim())
        .map((row, index) => ({
          key: row.key || `row-${index}`,
          title: row.title.trim(),
          description_internal: row.description_internal || null,
          is_required: row.is_required,
          evidence_required: row.evidence_required,
          response_type: meta.kind === 'todo' ? 'checkbox' : 'single_choice',
          response_set_id: null,
        })),
    [rows, meta.kind],
  )

  function runAction(
    action: () => Promise<{ ok: boolean; message: string }>,
    options: { refreshDetail?: boolean; closeDetail?: boolean } = {},
  ) {
    startTransition(async () => {
      try {
        const result = await action()
        setFeedback({ tone: result.ok ? 'success' : 'error', message: result.message })
        if (!result.ok) return

        reload(data.page)
        if (options.closeDetail) {
          setDetail(null)
        } else if (options.refreshDetail && detail) {
          loadDetail(detail.template.id)
        }
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }

  function handleCreate() {
    if (!createMeta.name.trim()) {
      setFeedback({ tone: 'error', message: 'El nom de la plantilla és obligatori.' })
      return
    }
    startTransition(async () => {
      try {
        const result = await createPlatformChecklistTemplate(toTemplateInput(createMeta))
        setFeedback({ tone: result.ok ? 'success' : 'error', message: result.message })
        if (!result.ok) return
        setCreating(false)
        setCreateMeta(emptyMeta())
        reload(1)
        if (result.templateId) loadDetail(result.templateId)
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }

  const editingVersion = detail?.editingVersion ?? null
  const isDraft = editingVersion?.status === 'draft'

  function addPointRow() {
    const point = points.find((p) => p.id === pointToAdd)
    if (!point) return
    setRows((prev) => [
      ...prev,
      {
        key: nextKey(),
        review_point_id: point.id,
        title: point.title,
        description_internal: point.description ?? '',
        description_public: point.client_text ?? point.description ?? '',
        include_in_report: true,
        is_required: false,
        evidence_required: false,
      },
    ])
    setPointToAdd('')
  }

  function addInlineRow() {
    setRows((prev) => [
      ...prev,
      {
        key: nextKey(),
        review_point_id: null,
        title: '',
        description_internal: '',
        description_public: '',
        include_in_report: false,
        is_required: false,
        evidence_required: false,
      },
    ])
  }

  function moveRow(index: number, delta: number) {
    setRows((prev) => {
      const target = index + delta
      if (target < 0 || target >= prev.length) return prev
      const next = [...prev]
      const [moved] = next.splice(index, 1)
      next.splice(target, 0, moved)
      return next
    })
  }

  function saveDraftItems() {
    if (!editingVersion) return
    const payload: DraftItemInput[] = rows.map((row) => ({
      review_point_id: row.review_point_id,
      title: row.title,
      description_internal: row.description_internal,
      description_public: row.description_public,
      include_in_report: row.include_in_report,
      is_required: row.is_required,
      evidence_required: row.evidence_required,
      response_type: row.review_point_id ? 'single_choice' : 'checkbox',
    }))
    runAction(() => savePlatformTemplateDraftItems(editingVersion.id, payload), {
      refreshDetail: true,
    })
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
              placeholder="Nom o descripció"
            />
          </Field>
          <Field label="Tipus">
            <select className={inputClass} value={kind} onChange={(e) => setKind(e.target.value)}>
              <option value="">Tots</option>
              {CHECKLIST_KINDS.map((code) => (
                <option key={code} value={code}>
                  {CHECKLIST_KIND_LABELS[code]}
                </option>
              ))}
            </select>
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
          <Field label="Arquetip">
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
          </Field>
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3">
          <label className="flex items-center gap-2 text-sm text-gray-700">
            <input
              type="checkbox"
              checked={includeArchived}
              onChange={(e) => setIncludeArchived(e.target.checked)}
            />
            Incloure arxivades
          </label>

          {canEdit && (
            <button
              type="button"
              className={primaryButtonClass}
              onClick={() => setCreating((v) => !v)}
              disabled={isPending}
            >
              {creating ? 'Cancel·lar' : '+ Nova plantilla'}
            </button>
          )}
        </div>

        {creating && canEdit && (
          <div className="space-y-3 rounded-xl border border-indigo-100 bg-indigo-50/40 p-3">
            <MetaFields meta={createMeta} setMeta={setCreateMeta} allowKindChange />
            <button type="button" className={primaryButtonClass} onClick={handleCreate} disabled={isPending}>
              {isPending ? 'Creant…' : 'Crear esborrany v1'}
            </button>
            <p className="text-xs text-gray-500">
              La plantilla es crea amb una versió esborrany buida. Afegeix-hi punts i publica-la
              perquè els plans de manteniment la puguin enllaçar.
            </p>
          </div>
        )}
      </section>

      <section className="space-y-3">
        <div className="overflow-x-auto rounded-lg border border-gray-200 bg-white">
          <table className="min-w-full divide-y divide-gray-200 text-sm">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Nom</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Tipus</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Taxonomia</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Versions</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Estat</th>
                <th className="px-4 py-3 text-right font-medium text-gray-700">Accions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {data.rows.length === 0 ? (
                <EmptyRow colSpan={6}>Cap plantilla de plataforma amb aquests filtres.</EmptyRow>
              ) : (
                data.rows.map((template) => (
                  <tr key={template.id} className={template.is_archived ? 'opacity-60' : undefined}>
                    <td className="px-4 py-3">
                      <p className="font-medium text-gray-900">{template.name}</p>
                      {template.description && (
                        <p className="mt-0.5 max-w-lg text-xs text-gray-500">{template.description}</p>
                      )}
                    </td>
                    <td className="px-4 py-3 text-gray-600">
                      {CHECKLIST_KIND_LABELS[template.kind as ChecklistKind] ?? template.kind}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex flex-wrap gap-1">
                        <Chip>{template.category}</Chip>
                        <Chip>{template.vertical}</Chip>
                        <Chip>
                          {CHECKLIST_LOCALE_LABELS[template.locale as ChecklistLocale] ??
                            template.locale}
                        </Chip>
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex flex-col gap-1">
                        {template.published_version_id ? (
                          <Chip tone="green">
                            Publicada v{template.published_version_number} ·{' '}
                            {template.published_item_count} punts
                          </Chip>
                        ) : (
                          <Chip tone="amber">Sense publicar</Chip>
                        )}
                        {template.draft_version_id && (
                          <Chip tone="indigo">
                            Esborrany v{template.draft_version_number} · {template.draft_item_count}{' '}
                            punts
                          </Chip>
                        )}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      {template.is_archived ? (
                        <Chip tone="amber">Arxivada</Chip>
                      ) : template.is_active ? (
                        <Chip tone="green">Activa</Chip>
                      ) : (
                        <Chip>Inactiva</Chip>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex justify-end gap-2">
                        <button
                          type="button"
                          className={secondaryButtonClass}
                          onClick={() => openListPreview(template.id)}
                          disabled={isPending}
                          title="Vista prèvia"
                          aria-label="Vista prèvia"
                        >
                          <Eye className="h-4 w-4" />
                        </button>
                        <button
                          type="button"
                          className={secondaryButtonClass}
                          onClick={() => loadDetail(template.id)}
                          disabled={isPending}
                        >
                          {canEdit ? 'Editar' : 'Veure'}
                        </button>
                        {canEdit && (
                          <>
                            <button
                              type="button"
                              className={secondaryButtonClass}
                              onClick={() =>
                                runAction(() => setPlatformTemplateActive(template.id, !template.is_active))
                              }
                              disabled={isPending || template.is_archived}
                            >
                              {template.is_active ? 'Desactivar' : 'Activar'}
                            </button>
                            <button
                              type="button"
                              className={dangerButtonClass}
                              onClick={() =>
                                runAction(() => archivePlatformChecklistTemplate(template.id), {
                                  closeDetail: detail?.template.id === template.id,
                                })
                              }
                              disabled={isPending || template.is_archived}
                            >
                              Arxivar
                            </button>
                          </>
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

      {detail && (
        <section className="space-y-5 rounded-2xl border border-indigo-100 bg-white p-4 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold text-gray-900">{detail.template.name}</h2>
              <p className="mt-1 text-xs text-gray-500">
                {editingVersion
                  ? `Editant v${editingVersion.version_number} (${
                      editingVersion.status === 'draft' ? 'esborrany' : editingVersion.status
                    })`
                  : 'Sense versions'}
              </p>
            </div>
            <button type="button" className={secondaryButtonClass} onClick={() => setDetail(null)}>
              Tancar
            </button>
          </div>

          <div className="rounded-xl border border-gray-100 bg-gray-50 p-3 text-xs text-gray-600">
            <p className="font-medium text-gray-700">Dependències</p>
            <ul className="mt-1 space-y-0.5">
              <li>
                Plans de manteniment:{' '}
                {detail.dependencies.plans.length === 0
                  ? 'cap'
                  : detail.dependencies.plans.map((p) => p.name).join(', ')}
              </li>
              <li>Clons de tenant: {detail.dependencies.tenantForks}</li>
              <li>Execucions (runs): {detail.dependencies.runs}</li>
            </ul>
          </div>

          {canEdit && (
            <div className="space-y-3">
              <h3 className="text-sm font-semibold text-gray-900">Metadades</h3>
              <MetaFields meta={meta} setMeta={setMeta} allowKindChange={!detail.template.published_version_id} />
              <button
                type="button"
                className={primaryButtonClass}
                onClick={() =>
                  runAction(() => updatePlatformChecklistTemplate(detail.template.id, toTemplateInput(meta)), {
                    refreshDetail: true,
                  })
                }
                disabled={isPending}
              >
                Desar metadades
              </button>
            </div>
          )}

          <div className="space-y-3">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-sm font-semibold text-gray-900">
                Punts de la versió ({rows.length})
              </h3>
              {canEdit && !isDraft && (
                <button
                  type="button"
                  className={secondaryButtonClass}
                  onClick={() =>
                    runAction(() => createPlatformTemplateDraft(detail.template.id), {
                      refreshDetail: true,
                    })
                  }
                  disabled={isPending}
                >
                  Obrir nou esborrany
                </button>
              )}
            </div>

            <Tabs
              value={editorTab}
              onValueChange={(v) => setEditorTab(v as 'edit' | 'preview')}
            >
              <TabsList>
                <TabsTrigger value="edit">Editar</TabsTrigger>
                <TabsTrigger value="preview">Vista prèvia</TabsTrigger>
              </TabsList>

              <TabsContent value="edit" className="mt-3 space-y-3">
                {!isDraft && (
                  <p className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                    Les versions publicades són immutables. Obre un nou esborrany per canviar-hi els
                    punts.
                  </p>
                )}

                {meta.kind === 'review' && isDraft && canEdit && (
                  <div className="flex flex-wrap items-end gap-2">
                    <Field label="Conjunt de respostes per defecte" className="min-w-64">
                      <select
                        className={inputClass}
                        value={defaultSetId}
                        onChange={(e) => setDefaultSetId(e.target.value)}
                      >
                        <option value="">— Cap —</option>
                        {responseSets.map((set) => (
                          <option key={set.id} value={set.id}>
                            {set.name} ({set.option_count} opcions)
                          </option>
                        ))}
                      </select>
                    </Field>
                    <button
                      type="button"
                      className={secondaryButtonClass}
                      onClick={() =>
                        editingVersion &&
                        runAction(
                          () =>
                            setPlatformTemplateDefaultResponseSet(
                              editingVersion.id,
                              defaultSetId || null,
                            ),
                          { refreshDetail: true },
                        )
                      }
                      disabled={isPending}
                    >
                      Desar conjunt
                    </button>
                    <p className="text-xs text-gray-500">
                      Obligatori per publicar plantilles de revisió si algun punt no en té un de propi.
                    </p>
                  </div>
                )}

                <div className="space-y-2">
                  {rows.length === 0 && (
                    <p className="rounded-lg border border-dashed border-gray-200 px-3 py-6 text-center text-sm text-gray-500">
                      Cap punt en aquesta versió. Cal com a mínim un punt per publicar.
                    </p>
                  )}

                  {rows.map((row, index) => (
                    <div
                      key={row.key}
                      className="grid gap-2 rounded-xl border border-gray-100 bg-gray-50/60 p-3 sm:grid-cols-[auto,1fr,auto]"
                    >
                      <div className="flex flex-col items-center gap-1 text-xs text-gray-500">
                        <span className="tabular-nums">{index + 1}</span>
                        {canEdit && isDraft && (
                          <>
                            <button
                              type="button"
                              onClick={() => moveRow(index, -1)}
                              className="px-1 disabled:opacity-30"
                              disabled={index === 0}
                            >
                              ↑
                            </button>
                            <button
                              type="button"
                              onClick={() => moveRow(index, 1)}
                              className="px-1 disabled:opacity-30"
                              disabled={index === rows.length - 1}
                            >
                              ↓
                            </button>
                          </>
                        )}
                      </div>

                      <div className="space-y-2">
                        {row.review_point_id ? (
                          <div>
                            <p className="text-sm font-medium text-gray-900">{row.title}</p>
                            <p className="text-xs text-gray-500">
                              Punt del catàleg · el text es resincronitza en publicar
                            </p>
                          </div>
                        ) : (
                          <input
                            className={inputClass}
                            value={row.title}
                            placeholder="Títol de la tasca"
                            disabled={!canEdit || !isDraft}
                            onChange={(e) =>
                              setRows((prev) =>
                                prev.map((r, i) => (i === index ? { ...r, title: e.target.value } : r)),
                              )
                            }
                          />
                        )}

                        <div className="flex flex-wrap gap-4 text-xs text-gray-600">
                          <label className="flex items-center gap-1.5">
                            <input
                              type="checkbox"
                              checked={row.include_in_report}
                              disabled={!canEdit || !isDraft}
                              onChange={(e) =>
                                setRows((prev) =>
                                  prev.map((r, i) =>
                                    i === index ? { ...r, include_in_report: e.target.checked } : r,
                                  ),
                                )
                              }
                            />
                            Al part del client
                          </label>
                          <label className="flex items-center gap-1.5">
                            <input
                              type="checkbox"
                              checked={row.is_required}
                              disabled={!canEdit || !isDraft}
                              onChange={(e) =>
                                setRows((prev) =>
                                  prev.map((r, i) =>
                                    i === index ? { ...r, is_required: e.target.checked } : r,
                                  ),
                                )
                              }
                            />
                            Obligatori
                          </label>
                          <label className="flex items-center gap-1.5">
                            <input
                              type="checkbox"
                              checked={row.evidence_required}
                              disabled={!canEdit || !isDraft}
                              onChange={(e) =>
                                setRows((prev) =>
                                  prev.map((r, i) =>
                                    i === index ? { ...r, evidence_required: e.target.checked } : r,
                                  ),
                                )
                              }
                            />
                            Requereix foto
                          </label>
                        </div>
                      </div>

                      {canEdit && isDraft && (
                        <button
                          type="button"
                          className={dangerButtonClass}
                          onClick={() => setRows((prev) => prev.filter((_, i) => i !== index))}
                        >
                          Treure
                        </button>
                      )}
                    </div>
                  ))}
                </div>

                {canEdit && isDraft && (
                  <div className="flex flex-wrap items-end gap-2">
                    <Field label="Afegir punt del catàleg" className="min-w-72">
                      <select
                        className={inputClass}
                        value={pointToAdd}
                        onChange={(e) => setPointToAdd(e.target.value)}
                      >
                        <option value="">— Tria un punt —</option>
                        {points.map((point) => (
                          <option key={point.id} value={point.id}>
                            {point.category} · {point.title}
                          </option>
                        ))}
                      </select>
                    </Field>
                    <button
                      type="button"
                      className={secondaryButtonClass}
                      onClick={addPointRow}
                      disabled={!pointToAdd}
                    >
                      Afegir punt
                    </button>
                    <button type="button" className={secondaryButtonClass} onClick={addInlineRow}>
                      + Tasca lliure
                    </button>
                    <button
                      type="button"
                      className={primaryButtonClass}
                      onClick={saveDraftItems}
                      disabled={isPending}
                    >
                      Desar esborrany
                    </button>
                    <button
                      type="button"
                      className={primaryButtonClass}
                      onClick={() =>
                        editingVersion &&
                        runAction(() => publishPlatformTemplateVersion(editingVersion.id), {
                          refreshDetail: true,
                        })
                      }
                      disabled={isPending || rows.length === 0 || detail.items.length === 0}
                      title={
                        detail.items.length === 0
                          ? 'Desa primer els punts de l’esborrany'
                          : 'Publicar la versió'
                      }
                    >
                      Publicar versió
                    </button>
                  </div>
                )}
              </TabsContent>

              <TabsContent value="preview" className="mt-3">
                {meta.kind === 'review' && !defaultSetId && (
                  <p className="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                    Sense conjunt de respostes per defecte: a la vista prèvia els botons de resposta
                    no apareixeran fins que n’assignis un.
                  </p>
                )}
                <PlatformChecklistTemplatePreview
                  kind={meta.kind}
                  items={previewItemsFromDraft}
                  responseSets={responseSets}
                  defaultResponseSetId={defaultSetId || null}
                />
              </TabsContent>
            </Tabs>
          </div>
        </section>
      )}

      <Dialog open={!!listPreview} onOpenChange={(open) => !open && setListPreview(null)}>
        <DialogContent className="max-h-[90dvh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{listPreview?.name ?? 'Vista prèvia'}</DialogTitle>
            <DialogDescription>
              Vista interactiva de la versió en edició (esborrany o publicada). Les respostes no es
              desen.
            </DialogDescription>
          </DialogHeader>
          {listPreview && (
            <PlatformChecklistTemplatePreview
              kind={listPreview.kind}
              items={listPreview.items}
              responseSets={responseSets}
              defaultResponseSetId={listPreview.defaultResponseSetId}
            />
          )}
        </DialogContent>
      </Dialog>
    </div>
  )
}

function MetaFields({
  meta,
  setMeta,
  allowKindChange,
}: {
  meta: MetaForm
  setMeta: (updater: (prev: MetaForm) => MetaForm) => void
  allowKindChange: boolean
}) {
  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <Field label="Nom" className="sm:col-span-2">
        <input
          className={inputClass}
          value={meta.name}
          onChange={(e) => setMeta((m) => ({ ...m, name: e.target.value }))}
        />
      </Field>
      <Field label="Tipus" hint={allowKindChange ? undefined : 'Blocat: ja hi ha una versió publicada.'}>
        <select
          className={inputClass}
          value={meta.kind}
          disabled={!allowKindChange}
          onChange={(e) => setMeta((m) => ({ ...m, kind: e.target.value as ChecklistKind }))}
        >
          {CHECKLIST_KINDS.map((code) => (
            <option key={code} value={code}>
              {CHECKLIST_KIND_LABELS[code]}
            </option>
          ))}
        </select>
      </Field>
      <Field label="Descripció" className="sm:col-span-2 lg:col-span-3">
        <textarea
          className={inputClass}
          rows={2}
          value={meta.description}
          onChange={(e) => setMeta((m) => ({ ...m, description: e.target.value }))}
        />
      </Field>
      <Field label="Idioma">
        <select
          className={inputClass}
          value={meta.locale}
          onChange={(e) => setMeta((m) => ({ ...m, locale: e.target.value as ChecklistLocale }))}
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
          value={meta.archetype}
          onChange={(e) => setMeta((m) => ({ ...m, archetype: e.target.value as ChecklistArchetype }))}
        >
          {CHECKLIST_ARCHETYPES.map((code) => (
            <option key={code} value={code}>
              {CHECKLIST_ARCHETYPE_LABELS[code]}
            </option>
          ))}
        </select>
      </Field>
      <Field label="Categoria">
        <input
          className={inputClass}
          value={meta.category}
          onChange={(e) => setMeta((m) => ({ ...m, category: e.target.value }))}
        />
      </Field>
      <Field label="Vertical">
        <input
          className={inputClass}
          value={meta.vertical}
          onChange={(e) => setMeta((m) => ({ ...m, vertical: e.target.value }))}
        />
      </Field>
      <label className="flex items-end gap-2 pb-2 text-sm text-gray-700">
        <input
          type="checkbox"
          checked={meta.is_active}
          onChange={(e) => setMeta((m) => ({ ...m, is_active: e.target.checked }))}
        />
        Activa
      </label>
    </div>
  )
}

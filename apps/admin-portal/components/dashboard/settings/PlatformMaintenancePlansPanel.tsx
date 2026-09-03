'use client'

import { useCallback, useEffect, useState, useTransition } from 'react'
import {
  archivePlatformMaintenancePlan,
  createPlatformMaintenancePlan,
  getPlatformMaintenancePlan,
  listPlatformMaintenancePlans,
  setPlatformMaintenancePlanActive,
  updatePlatformMaintenancePlan,
  type MaintenancePlanInput,
  type PlatformMaintenancePlan,
  type PlatformPlanChecklist,
  type PublishedPlatformTemplateOption,
} from '@/app/admin/actions/maintenance-plans'
import {
  CHECKLIST_ARCHETYPES,
  CHECKLIST_ARCHETYPE_LABELS,
  CHECKLIST_KIND_LABELS,
  CHECKLIST_LOCALES,
  CHECKLIST_LOCALE_LABELS,
  DEFAULT_TIMEZONE,
  MAINTENANCE_FREQUENCIES,
  MAINTENANCE_FREQUENCY_LABELS,
  describePeriodicity,
  type ChecklistArchetype,
  type ChecklistKind,
  type ChecklistLocale,
  type MaintenanceFrequency,
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
  initial: PagedResult<PlatformMaintenancePlan>
  templates: PublishedPlatformTemplateOption[]
  canEdit: boolean
}

interface PlanForm {
  name: string
  description: string
  locale: ChecklistLocale
  category: string
  vertical: string
  archetype: ChecklistArchetype
  frequency: MaintenanceFrequency
  interval_count: number
  byweekday: number[]
  bymonthday: string
  timezone: string
  lead_days: number
  is_active: boolean
  templateIds: string[]
}

const WEEKDAY_LABELS = ['Dl', 'Dt', 'Dc', 'Dj', 'Dv', 'Ds', 'Dg']

function emptyForm(): PlanForm {
  return {
    name: '',
    description: '',
    locale: 'ca',
    category: 'general',
    vertical: 'generic',
    archetype: 'field_service',
    frequency: 'monthly',
    interval_count: 1,
    byweekday: [],
    bymonthday: '',
    timezone: DEFAULT_TIMEZONE,
    lead_days: 0,
    is_active: true,
    templateIds: [],
  }
}

function formFromPlan(plan: PlatformMaintenancePlan, templateIds: string[]): PlanForm {
  return {
    name: plan.name,
    description: plan.description ?? '',
    locale: plan.locale as ChecklistLocale,
    category: plan.category,
    vertical: plan.vertical,
    archetype: plan.archetype as ChecklistArchetype,
    frequency: plan.frequency as MaintenanceFrequency,
    interval_count: plan.interval_count,
    byweekday: plan.byweekday ?? [],
    bymonthday: plan.bymonthday != null ? String(plan.bymonthday) : '',
    timezone: plan.timezone,
    lead_days: plan.lead_days,
    is_active: plan.is_active,
    templateIds,
  }
}

function toInput(form: PlanForm): MaintenancePlanInput {
  const bymonthday = form.bymonthday.trim() ? Number(form.bymonthday) : null
  return {
    name: form.name,
    description: form.description,
    locale: form.locale,
    category: form.category,
    vertical: form.vertical,
    archetype: form.archetype,
    frequency: form.frequency,
    interval_count: form.interval_count,
    byweekday: form.byweekday,
    bymonthday: Number.isFinite(bymonthday) ? bymonthday : null,
    timezone: form.timezone,
    lead_days: form.lead_days,
    is_active: form.is_active,
    templateIds: form.templateIds,
  }
}

export function PlatformMaintenancePlansPanel({ initial, templates, canEdit }: Props) {
  const [data, setData] = useState(initial)
  const [isPending, startTransition] = useTransition()
  const [feedback, setFeedback] = useState<{ tone: 'success' | 'error'; message: string } | null>(null)

  const [search, setSearch] = useState('')
  const [locale, setLocale] = useState('')
  const [archetype, setArchetype] = useState('')
  const [vertical, setVertical] = useState('')
  const [includeArchived, setIncludeArchived] = useState(false)

  const [editingId, setEditingId] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [form, setForm] = useState<PlanForm>(emptyForm())
  const [hierarchy, setHierarchy] = useState<PlatformPlanChecklist[]>([])

  const reload = useCallback(
    (nextPage = 1) => {
      startTransition(async () => {
        try {
          const result = await listPlatformMaintenancePlans({
            search,
            locale: locale || undefined,
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
    [search, locale, vertical, archetype, includeArchived],
  )

  useEffect(() => {
    const handle = setTimeout(() => reload(1), 300)
    return () => clearTimeout(handle)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search, locale, vertical, archetype, includeArchived])

  function openCreate() {
    setEditingId(null)
    setForm(emptyForm())
    setHierarchy([])
    setFormOpen(true)
  }

  function openEdit(plan: PlatformMaintenancePlan) {
    startTransition(async () => {
      try {
        const detail = await getPlatformMaintenancePlan(plan.id)
        setEditingId(plan.id)
        setForm(
          formFromPlan(
            detail.plan,
            detail.checklists.map((c) => c.template_id),
          ),
        )
        setHierarchy(detail.checklists)
        setFormOpen(true)
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }

  function runAction(action: () => Promise<{ ok: boolean; message: string }>, closeForm = false) {
    startTransition(async () => {
      try {
        const result = await action()
        setFeedback({ tone: result.ok ? 'success' : 'error', message: result.message })
        if (!result.ok) return
        if (closeForm) {
          setFormOpen(false)
          setEditingId(null)
        }
        reload(data.page)
      } catch (err) {
        setFeedback({ tone: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    })
  }

  function handleSubmit() {
    if (!form.name.trim()) {
      setFeedback({ tone: 'error', message: 'El nom del pla és obligatori.' })
      return
    }
    if (form.templateIds.length === 0) {
      setFeedback({
        tone: 'error',
        message: 'Enllaça almenys una plantilla publicada: sense checklists el pla generaria ordres buides.',
      })
      return
    }
    const input = toInput(form)
    runAction(
      () =>
        editingId
          ? updatePlatformMaintenancePlan(editingId, input)
          : createPlatformMaintenancePlan(input),
      true,
    )
  }

  function toggleTemplate(templateId: string) {
    setForm((f) => ({
      ...f,
      templateIds: f.templateIds.includes(templateId)
        ? f.templateIds.filter((id) => id !== templateId)
        : [...f.templateIds, templateId],
    }))
  }

  function moveTemplate(index: number, delta: number) {
    setForm((f) => {
      const target = index + delta
      if (target < 0 || target >= f.templateIds.length) return f
      const next = [...f.templateIds]
      const [moved] = next.splice(index, 1)
      next.splice(target, 0, moved)
      return { ...f, templateIds: next }
    })
  }

  const templatesById = new Map(templates.map((t) => [t.id, t]))

  return (
    <div className="space-y-4">
      {feedback && (
        <Banner tone={feedback.tone} message={feedback.message} onDismiss={() => setFeedback(null)} />
      )}

      {templates.length === 0 && (
        <Banner
          tone="info"
          message="No hi ha cap plantilla de checklist de plataforma publicada. Publica'n una abans de crear plans."
        />
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
          <Field label="Vertical">
            <input
              className={inputClass}
              value={vertical}
              onChange={(e) => setVertical(e.target.value)}
              placeholder="Ex: plumbing"
            />
          </Field>
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3">
          <label className="flex items-center gap-2 text-sm text-gray-700">
            <input
              type="checkbox"
              checked={includeArchived}
              onChange={(e) => setIncludeArchived(e.target.checked)}
            />
            Incloure arxivats
          </label>

          {canEdit && (
            <button
              type="button"
              className={primaryButtonClass}
              onClick={openCreate}
              disabled={isPending || templates.length === 0}
            >
              + Nou pla
            </button>
          )}
        </div>
      </section>

      {formOpen && canEdit && (
        <section className="space-y-4 rounded-2xl border border-indigo-100 bg-white p-4 shadow-sm">
          <h2 className="text-base font-semibold text-gray-900">
            {editingId ? 'Editar pla de plataforma' : 'Nou pla de plataforma'}
          </h2>

          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <Field label="Nom" className="sm:col-span-2">
              <input
                className={inputClass}
                value={form.name}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                placeholder="Ex: Manteniment anual de caldera"
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
            <Field label="Descripció" className="sm:col-span-2 lg:col-span-3">
              <textarea
                className={inputClass}
                rows={2}
                value={form.description}
                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
              />
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
            <Field label="Categoria">
              <input
                className={inputClass}
                value={form.category}
                onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
              />
            </Field>
            <Field label="Vertical">
              <input
                className={inputClass}
                value={form.vertical}
                onChange={(e) => setForm((f) => ({ ...f, vertical: e.target.value }))}
              />
            </Field>
          </div>

          <div className="space-y-3 rounded-xl border border-gray-100 bg-gray-50/60 p-3">
            <h3 className="text-sm font-semibold text-gray-900">Periodicitat per defecte</h3>
            <p className="text-xs text-gray-500">
              Es copia a cada assignació del tenant; després es pot sobreescriure per assignació.
            </p>

            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <Field label="Freqüència">
                <select
                  className={inputClass}
                  value={form.frequency}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, frequency: e.target.value as MaintenanceFrequency }))
                  }
                >
                  {MAINTENANCE_FREQUENCIES.map((code) => (
                    <option key={code} value={code}>
                      {MAINTENANCE_FREQUENCY_LABELS[code]}
                    </option>
                  ))}
                </select>
              </Field>
              <Field label="Cada" hint="Nombre de períodes entre visites.">
                <input
                  type="number"
                  min={1}
                  className={inputClass}
                  value={form.interval_count}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, interval_count: Math.max(1, Number(e.target.value) || 1) }))
                  }
                />
              </Field>
              <Field label="Zona horària">
                <input
                  className={inputClass}
                  value={form.timezone}
                  onChange={(e) => setForm((f) => ({ ...f, timezone: e.target.value }))}
                />
              </Field>
              <Field label="Dies d'avís" hint="Genera l'ordre X dies abans del venciment.">
                <input
                  type="number"
                  min={0}
                  className={inputClass}
                  value={form.lead_days}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, lead_days: Math.max(0, Number(e.target.value) || 0) }))
                  }
                />
              </Field>
            </div>

            {form.frequency === 'weekly' && (
              <Field label="Dies de la setmana">
                <div className="flex flex-wrap gap-2">
                  {WEEKDAY_LABELS.map((label, day) => (
                    <label key={day} className="flex items-center gap-1 text-sm text-gray-700">
                      <input
                        type="checkbox"
                        checked={form.byweekday.includes(day)}
                        onChange={(e) =>
                          setForm((f) => ({
                            ...f,
                            byweekday: e.target.checked
                              ? [...f.byweekday, day].sort((a, b) => a - b)
                              : f.byweekday.filter((d) => d !== day),
                          }))
                        }
                      />
                      {label}
                    </label>
                  ))}
                </div>
              </Field>
            )}

            {form.frequency === 'monthly' && (
              <Field label="Dia del mes" hint="Deixa-ho buit per usar el dia de la primera assignació.">
                <input
                  type="number"
                  min={1}
                  max={31}
                  className={`${inputClass} max-w-32`}
                  value={form.bymonthday}
                  onChange={(e) => setForm((f) => ({ ...f, bymonthday: e.target.value }))}
                />
              </Field>
            )}
          </div>

          <div className="space-y-3 rounded-xl border border-gray-100 bg-gray-50/60 p-3">
            <h3 className="text-sm font-semibold text-gray-900">
              Jerarquia: pla → plantilles → punts
            </h3>
            <p className="text-xs text-gray-500">
              El pla només enganxa plantilles publicades. Els punts viuen dins de cada plantilla.
            </p>
            {form.templateIds.length === 0 && (
              <p className="text-xs text-red-600">
                Cal com a mínim una plantilla per poder desar el pla.
              </p>
            )}

            <ol className="space-y-3">
              {form.templateIds.map((templateId, index) => {
                const template = templatesById.get(templateId)
                const detail = hierarchy.find((c) => c.template_id === templateId)
                return (
                  <li
                    key={templateId}
                    className="rounded-lg border border-gray-200 bg-white px-3 py-2 space-y-2"
                  >
                    <div className="flex items-center justify-between gap-3">
                      <div className="flex items-center gap-2 text-sm min-w-0">
                        <span className="tabular-nums text-gray-400">{index + 1}.</span>
                        <span className="font-medium text-gray-900 truncate">
                          {template?.name ?? detail?.template_name ?? templateId}
                        </span>
                        {template && (
                          <Chip>
                            {CHECKLIST_KIND_LABELS[template.kind as ChecklistKind] ?? template.kind} · v
                            {template.version_number} · {template.item_count} punts
                          </Chip>
                        )}
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          type="button"
                          className="px-1 text-gray-500 disabled:opacity-30"
                          onClick={() => moveTemplate(index, -1)}
                          disabled={index === 0}
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          className="px-1 text-gray-500 disabled:opacity-30"
                          onClick={() => moveTemplate(index, 1)}
                          disabled={index === form.templateIds.length - 1}
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          className="ml-1 text-xs text-red-600 underline"
                          onClick={() => toggleTemplate(templateId)}
                        >
                          Treure
                        </button>
                      </div>
                    </div>
                    {detail && detail.items.length > 0 ? (
                      <ol className="ml-5 space-y-1 border-l border-gray-100 pl-3">
                        {detail.items.map((item) => (
                          <li key={item.id} className="text-xs text-gray-600">
                            <span className="tabular-nums text-gray-400 mr-1">{item.position + 1}.</span>
                            {item.title}
                          </li>
                        ))}
                      </ol>
                    ) : template ? (
                      <p className="ml-5 text-xs text-gray-400">
                        {template.item_count} ítems a la versió publicada
                      </p>
                    ) : null}
                  </li>
                )
              })}
            </ol>

            <Field label="Afegir plantilla">
              <select
                className={inputClass}
                value=""
                onChange={(e) => e.target.value && toggleTemplate(e.target.value)}
              >
                <option value="">— Tria una plantilla publicada —</option>
                {templates
                  .filter((t) => !form.templateIds.includes(t.id))
                  .map((template) => (
                    <option key={template.id} value={template.id}>
                      {template.name} (v{template.version_number}, {template.item_count} punts)
                    </option>
                  ))}
              </select>
            </Field>
          </div>

          <label className="flex items-center gap-2 text-sm text-gray-700">
            <input
              type="checkbox"
              checked={form.is_active}
              onChange={(e) => setForm((f) => ({ ...f, is_active: e.target.checked }))}
            />
            Actiu (visible a la biblioteca dels tenants)
          </label>

          <div className="flex gap-2">
            <button type="button" className={primaryButtonClass} onClick={handleSubmit} disabled={isPending}>
              {isPending ? 'Desant…' : 'Desar pla'}
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
                <th className="px-4 py-3 text-left font-medium text-gray-700">Nom</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Taxonomia</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Periodicitat</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Checklists</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Clons</th>
                <th className="px-4 py-3 text-left font-medium text-gray-700">Estat</th>
                {canEdit && <th className="px-4 py-3 text-right font-medium text-gray-700">Accions</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {data.rows.length === 0 ? (
                <EmptyRow colSpan={canEdit ? 7 : 6}>
                  Cap pla de manteniment de plataforma amb aquests filtres.
                </EmptyRow>
              ) : (
                data.rows.map((plan) => (
                  <tr key={plan.id} className={plan.is_archived ? 'opacity-60' : undefined}>
                    <td className="px-4 py-3">
                      <p className="font-medium text-gray-900">{plan.name}</p>
                      {plan.description && (
                        <p className="mt-0.5 max-w-lg text-xs text-gray-500">{plan.description}</p>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex flex-wrap gap-1">
                        <Chip>{plan.category}</Chip>
                        <Chip>{plan.vertical}</Chip>
                        <Chip tone="indigo">
                          {CHECKLIST_ARCHETYPE_LABELS[plan.archetype as ChecklistArchetype] ??
                            plan.archetype}
                        </Chip>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-gray-600">{describePeriodicity(plan)}</td>
                    <td className="px-4 py-3">
                      {plan.checklist_count === 0 ? (
                        <Chip tone="amber">Cap</Chip>
                      ) : (
                        <Chip tone="green">{plan.checklist_count}</Chip>
                      )}
                    </td>
                    <td className="px-4 py-3 text-gray-600 tabular-nums">{plan.tenant_clones}</td>
                    <td className="px-4 py-3">
                      {plan.is_archived ? (
                        <Chip tone="amber">Arxivat</Chip>
                      ) : plan.is_active ? (
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
                            onClick={() => openEdit(plan)}
                            disabled={isPending}
                          >
                            Editar
                          </button>
                          <button
                            type="button"
                            className={secondaryButtonClass}
                            onClick={() =>
                              runAction(() =>
                                setPlatformMaintenancePlanActive(plan.id, !plan.is_active),
                              )
                            }
                            disabled={isPending || plan.is_archived}
                          >
                            {plan.is_active ? 'Desactivar' : 'Activar'}
                          </button>
                          <button
                            type="button"
                            className={dangerButtonClass}
                            onClick={() => runAction(() => archivePlatformMaintenancePlan(plan.id))}
                            disabled={isPending || plan.is_archived}
                          >
                            Arxivar
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

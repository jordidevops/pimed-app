'use client'

import { useState, useTransition } from 'react'
import {
  listPlatformCalculators,
  updateCalculatorCatalogSettings,
  updatePlatformCalculatorVisibility,
  type CalculatorCatalogSettings,
  type PlatformCalculator,
} from '@/app/admin/actions/price-calculators'
import {
  CHECKLIST_ARCHETYPES,
  CHECKLIST_ARCHETYPE_LABELS,
  CHECKLIST_LOCALES,
  type ChecklistArchetype,
  type ChecklistLocale,
} from '@/lib/platform-catalog/constants'
import {
  Banner,
  Chip,
  EmptyRow,
  Field,
  inputClass,
  primaryButtonClass,
  secondaryButtonClass,
} from './CatalogControls'

interface Props {
  initial: PlatformCalculator[]
  settings: CalculatorCatalogSettings
  canEdit: boolean
}

type LocaleMap = Record<ChecklistLocale, string>

function emptyLocaleMap(seed?: Record<string, string> | null): LocaleMap {
  return {
    ca: seed?.ca ?? '',
    es: seed?.es ?? '',
    en: seed?.en ?? '',
  }
}

function toLocaleRecord(map: LocaleMap): Record<string, string> {
  const out: Record<string, string> = {}
  for (const loc of CHECKLIST_LOCALES) {
    const v = map[loc].trim()
    if (v) out[loc] = v
  }
  return out
}

export function PlatformPriceCalculatorsPanel({ initial, settings, canEdit }: Props) {
  const [rows, setRows] = useState(initial)
  const [crossArchetype, setCrossArchetype] = useState(settings.show_cross_archetype_catalog)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [archetypes, setArchetypes] = useState<string[]>([])
  const [isActive, setIsActive] = useState(true)
  const [title, setTitle] = useState<LocaleMap>(emptyLocaleMap())
  const [summary, setSummary] = useState<LocaleMap>(emptyLocaleMap())
  const [banner, setBanner] = useState<{ tone: 'success' | 'error' | 'info'; message: string } | null>(
    null,
  )
  const [pending, startTransition] = useTransition()

  function openEdit(row: PlatformCalculator) {
    setEditingId(row.id)
    setArchetypes([...row.target_archetypes])
    setIsActive(row.is_active)
    setTitle(emptyLocaleMap(row.title))
    setSummary(emptyLocaleMap(row.summary))
    setBanner(null)
  }

  function toggleArchetype(arch: ChecklistArchetype) {
    setArchetypes((prev) =>
      prev.includes(arch) ? prev.filter((a) => a !== arch) : [...prev, arch],
    )
  }

  function refresh() {
    startTransition(async () => {
      try {
        const next = await listPlatformCalculators()
        setRows(next)
      } catch (err) {
        setBanner({
          tone: 'error',
          message: err instanceof Error ? err.message : 'Error carregant',
        })
      }
    })
  }

  function saveRow() {
    if (!editingId) return
    startTransition(async () => {
      const result = await updatePlatformCalculatorVisibility({
        id: editingId,
        target_archetypes: archetypes,
        is_active: isActive,
        title: toLocaleRecord(title),
        summary: toLocaleRecord(summary),
      })
      setBanner({
        tone: result.ok ? 'success' : 'error',
        message: result.message,
      })
      if (result.ok) {
        setEditingId(null)
        refresh()
      }
    })
  }

  function saveSettings(next: boolean) {
    setCrossArchetype(next)
    startTransition(async () => {
      const result = await updateCalculatorCatalogSettings({
        show_cross_archetype_catalog: next,
      })
      setBanner({
        tone: result.ok ? 'success' : 'error',
        message: result.message,
      })
      if (!result.ok) setCrossArchetype(!next)
    })
  }

  const editing = rows.find((r) => r.id === editingId) ?? null

  return (
    <div className="space-y-6">
      {banner && (
        <Banner tone={banner.tone} message={banner.message} onDismiss={() => setBanner(null)} />
      )}

      <section className="rounded-lg border border-gray-200 bg-white p-4">
        <h2 className="text-sm font-semibold text-gray-900">Visibilitat biblioteca</h2>
        <p className="mt-1 text-sm text-gray-500">
          Quan està actiu, els tenants veuen també models d&apos;altres arquetips (amb badge).
        </p>
        <label className="mt-3 flex items-center gap-2 text-sm text-gray-800">
          <input
            type="checkbox"
            className="rounded border-gray-300"
            checked={crossArchetype}
            disabled={!canEdit || pending}
            onChange={(e) => saveSettings(e.target.checked)}
          />
          Els tenants poden veure calculadores d&apos;altres arquetips
        </label>
      </section>

      <section className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <div className="border-b border-gray-100 px-4 py-3">
          <h2 className="text-sm font-semibold text-gray-900">Catàleg de plataforma</h2>
          <p className="text-xs text-gray-500">{rows.length} models</p>
        </div>
        <table className="min-w-full divide-y divide-gray-100 text-sm">
          <thead className="bg-gray-50 text-left text-xs uppercase tracking-wide text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">Slug</th>
              <th className="px-4 py-2 font-medium">Títol (ca)</th>
              <th className="px-4 py-2 font-medium">Arquetips</th>
              <th className="px-4 py-2 font-medium">Estat</th>
              <th className="px-4 py-2 font-medium" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {rows.length === 0 && (
              <EmptyRow colSpan={5}>Cap calculadora al catàleg</EmptyRow>
            )}
            {rows.map((row) => (
              <tr key={row.id} className="hover:bg-gray-50/80">
                <td className="px-4 py-2 font-mono text-xs text-gray-700">{row.slug}</td>
                <td className="px-4 py-2 text-gray-900">{row.title?.ca ?? '—'}</td>
                <td className="px-4 py-2">
                  <div className="flex flex-wrap gap-1">
                    {row.target_archetypes.map((a) => (
                      <Chip key={a} tone="indigo">
                        {CHECKLIST_ARCHETYPE_LABELS[a as ChecklistArchetype] ?? a}
                      </Chip>
                    ))}
                  </div>
                </td>
                <td className="px-4 py-2">
                  <Chip tone={row.is_active ? 'green' : 'gray'}>
                    {row.is_active ? 'Activa' : 'Inactiva'}
                  </Chip>
                </td>
                <td className="px-4 py-2 text-right">
                  {canEdit && (
                    <button
                      type="button"
                      className={secondaryButtonClass}
                      onClick={() => openEdit(row)}
                      disabled={pending}
                    >
                      Editar
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {editing && canEdit && (
        <section className="space-y-4 rounded-lg border border-indigo-100 bg-indigo-50/40 p-4">
          <div className="flex items-center justify-between gap-3">
            <div>
              <h3 className="text-sm font-semibold text-gray-900">Editar · {editing.slug}</h3>
              <p className="text-xs text-gray-500">Sense edició de l&apos;AST en aquesta versió.</p>
            </div>
            <button
              type="button"
              className={secondaryButtonClass}
              onClick={() => setEditingId(null)}
              disabled={pending}
            >
              Tancar
            </button>
          </div>

          <Field label="Arquetips objectiu">
            <div className="flex flex-wrap gap-2">
              {CHECKLIST_ARCHETYPES.map((arch) => (
                <label
                  key={arch}
                  className="inline-flex items-center gap-1.5 rounded-md border border-gray-200 bg-white px-2 py-1 text-xs"
                >
                  <input
                    type="checkbox"
                    checked={archetypes.includes(arch)}
                    onChange={() => toggleArchetype(arch)}
                    disabled={pending}
                  />
                  {CHECKLIST_ARCHETYPE_LABELS[arch]}
                </label>
              ))}
            </div>
          </Field>

          <label className="flex items-center gap-2 text-sm text-gray-800">
            <input
              type="checkbox"
              className="rounded border-gray-300"
              checked={isActive}
              disabled={pending}
              onChange={(e) => setIsActive(e.target.checked)}
            />
            Visible a la biblioteca (`is_active`)
          </label>

          <div className="grid gap-3 md:grid-cols-3">
            {CHECKLIST_LOCALES.map((loc) => (
              <Field key={`title-${loc}`} label={`Títol (${loc})`}>
                <input
                  className={inputClass}
                  value={title[loc]}
                  onChange={(e) => setTitle((t) => ({ ...t, [loc]: e.target.value }))}
                  disabled={pending}
                />
              </Field>
            ))}
          </div>
          <div className="grid gap-3 md:grid-cols-3">
            {CHECKLIST_LOCALES.map((loc) => (
              <Field key={`summary-${loc}`} label={`Resum (${loc})`}>
                <textarea
                  className={inputClass}
                  rows={2}
                  value={summary[loc]}
                  onChange={(e) => setSummary((s) => ({ ...s, [loc]: e.target.value }))}
                  disabled={pending}
                />
              </Field>
            ))}
          </div>

          <div className="flex justify-end gap-2">
            <button
              type="button"
              className={secondaryButtonClass}
              onClick={() => setEditingId(null)}
              disabled={pending}
            >
              Cancel·lar
            </button>
            <button
              type="button"
              className={primaryButtonClass}
              onClick={saveRow}
              disabled={pending || archetypes.length === 0}
            >
              Desar
            </button>
          </div>
        </section>
      )}
    </div>
  )
}

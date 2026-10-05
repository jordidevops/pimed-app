import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Layers, Pencil, Plus, PowerOff, Search } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { PageShell } from '@/components/layout/PageShell'
import { InspectorSheet } from '@/components/layout/InspectorSheet'
import { useToast } from '@/hooks/use-toast'
import {
  deactivatePricingTemplate,
  listPricingTemplateChecklists,
  listPricingTemplateItems,
  listPricingTemplates,
  type PricingTemplate,
  type PricingTemplateItem,
} from '@/features/commercial/api/commercialFlowService'
import { listPublishedTemplatesForTenant } from '@/features/field-service/api/checklistTemplatesService'
import { getCatalogItems } from '../api/catalogService'
import { PricingTemplateForm } from './PricingTemplateForm'

const currencyFormatter = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

export function CatalogPacksPage() {
  const { t } = useTranslation('catalog')
  const { activeTenant, tenantsLoading } = useTenant()
  const queryClient = useQueryClient()
  const { toast } = useToast()

  const [search, setSearch] = useState('')
  const [categoryFilter, setCategoryFilter] = useState<string | null>(null)
  const [inspectId, setInspectId] = useState<string | null>(null)
  const [packFormOpen, setPackFormOpen] = useState(false)
  const [editPack, setEditPack] = useState<PricingTemplate | null>(null)
  const [packItemCounts, setPackItemCounts] = useState<Record<string, number>>({})

  const {
    data: packs = [],
    isLoading: packsLoading,
    error: packsError,
  } = useQuery({
    queryKey: ['pricing_templates', activeTenant?.id],
    queryFn: listPricingTemplates,
    enabled: !!activeTenant,
  })

  const inspectedPack = useMemo(
    () => packs.find((p) => p.id === inspectId) ?? null,
    [packs, inspectId],
  )

  const { data: inspectLines = [], isLoading: linesLoading } = useQuery({
    queryKey: ['pricing_template_items', inspectId],
    queryFn: () => listPricingTemplateItems(inspectId!),
    enabled: !!inspectId,
  })

  const { data: inspectChecklists = [] } = useQuery({
    queryKey: ['pricing_template_checklists', inspectId],
    queryFn: () => listPricingTemplateChecklists(inspectId!),
    enabled: !!inspectId,
  })

  const { data: checklistTemplates = [] } = useQuery({
    queryKey: ['checklist_templates_published', activeTenant?.id],
    queryFn: () => listPublishedTemplatesForTenant(activeTenant!.id!),
    enabled: !!inspectId && !!activeTenant?.id,
  })

  const { data: catalogItems = [] } = useQuery({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: getCatalogItems,
    enabled: !!inspectId && !!activeTenant,
  })

  const checklistNameById = useMemo(() => {
    const map = new Map<string, string>()
    for (const tpl of checklistTemplates) map.set(tpl.id, tpl.name)
    return map
  }, [checklistTemplates])

  const catalogNameById = useMemo(() => {
    const map = new Map<string, { name: string; unit: string | null; price: number | null }>()
    for (const item of catalogItems) {
      if (!item.id) continue
      map.set(item.id, {
        name: item.name ?? item.id,
        unit: item.unit,
        price: item.unit_price,
      })
    }
    return map
  }, [catalogItems])

  const categories = useMemo(() => {
    const set = new Set<string>()
    for (const pack of packs) {
      if (pack.category?.trim()) set.add(pack.category.trim())
    }
    return Array.from(set).sort((a, b) => a.localeCompare(b, 'ca'))
  }, [packs])

  const filteredPacks = useMemo(() => {
    let result = packs
    if (categoryFilter) {
      result = result.filter((p) => (p.category ?? '').trim() === categoryFilter)
    }
    if (search.trim()) {
      const q = search.trim().toLowerCase()
      result = result.filter(
        (p) =>
          p.name.toLowerCase().includes(q) ||
          (p.description ?? '').toLowerCase().includes(q) ||
          (p.category ?? '').toLowerCase().includes(q),
      )
    }
    return result
  }, [packs, search, categoryFilter])

  useEffect(() => {
    if (packs.length === 0) {
      setPackItemCounts({})
      return
    }
    let cancelled = false
    void (async () => {
      const entries = await Promise.all(
        packs.map(async (pack) => {
          try {
            const rows = await listPricingTemplateItems(pack.id)
            return [pack.id, rows.length] as const
          } catch {
            return [pack.id, 0] as const
          }
        }),
      )
      if (!cancelled) setPackItemCounts(Object.fromEntries(entries))
    })()
    return () => {
      cancelled = true
    }
  }, [packs])

  function handleNew() {
    setEditPack(null)
    setPackFormOpen(true)
  }

  function handleEdit(pack: PricingTemplate) {
    setEditPack(pack)
    setPackFormOpen(true)
  }

  async function handleDeactivate(pack: PricingTemplate) {
    const confirmed = window.confirm(
      t(
        'catalog.packs.deactivate_confirm',
        'Confirmes que vols desactivar aquest servei habitual?',
      ),
    )
    if (!confirmed) return
    try {
      await deactivatePricingTemplate(pack.id)
      if (inspectId === pack.id) setInspectId(null)
      queryClient.invalidateQueries({ queryKey: ['pricing_templates'] })
      toast({ title: t('catalog.packs.deactivated', 'Servei habitual desactivat') })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('catalog.packs.deactivate_failed', "No s'ha pogut desactivar"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  if (tenantsLoading) {
    return (
      <div className="flex h-48 items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (!activeTenant) return null

  const inspector =
    inspectedPack ? (
      <InspectorSheet
        title={inspectedPack.name}
        subtitle={inspectedPack.description || undefined}
        badges={
          <>
            {inspectedPack.category ? (
              <Badge variant="outline">{inspectedPack.category}</Badge>
            ) : null}
            {inspectedPack.is_default ? (
              <Badge variant="secondary">
                {t('catalog.packs.default', 'Per defecte')}
              </Badge>
            ) : null}
          </>
        }
        fields={[
          {
            label: t('catalog.columns.category', 'Categoria'),
            value: inspectedPack.category ?? '—',
          },
          {
            label: t('catalog.packs.lines', 'Línies'),
            value: String(packItemCounts[inspectedPack.id] ?? inspectLines.length ?? '—'),
          },
          {
            label: t('catalog.packs.default', 'Per defecte'),
            value: inspectedPack.is_default
              ? t('catalog.packs.yes', 'Sí')
              : t('catalog.packs.no', 'No'),
          },
        ]}
        onClose={() => setInspectId(null)}
        footer={
          <>
            <Button type="button" size="sm" onClick={() => handleEdit(inspectedPack)}>
              <Pencil className="mr-1.5 h-3.5 w-3.5" />
              {t('catalog.actions.edit', 'Editar')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => void handleDeactivate(inspectedPack)}
            >
              <PowerOff className="mr-1.5 h-3.5 w-3.5" />
              {t('catalog.actions.deactivate', 'Desactivar')}
            </Button>
          </>
        }
      >
        <div className="space-y-4">
          <div>
            <h3 className="mb-2 text-sm font-semibold text-foreground">
              {t('catalog.packs.items_title', 'Línies del pack')}
            </h3>
            {linesLoading ? (
              <p className="text-sm text-muted-foreground">
                {t('catalog.packs.loading_lines', 'Carregant línies…')}
              </p>
            ) : inspectLines.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('catalog.packs.no_lines', 'Sense línies')}
              </p>
            ) : (
              <ul className="space-y-2">
                {inspectLines.map((line: PricingTemplateItem) => {
                  const catalog = catalogNameById.get(line.catalog_item_id)
                  const unit = line.catalog_item_unit ?? catalog?.unit
                  const price = line.catalog_item_unit_price ?? catalog?.price ?? null
                  return (
                    <li
                      key={line.id}
                      className="rounded-lg border border-border px-3 py-2 text-sm"
                    >
                      <p className="font-medium text-foreground">
                        {line.catalog_item_name ?? catalog?.name ?? line.catalog_item_id}
                      </p>
                      <p className="mt-0.5 text-xs text-muted-foreground">
                        {t('catalog.packs.qty', 'Quantitat')}: {line.default_quantity}
                        {unit ? ` ${unit}` : ''}
                        {price != null ? ` · ${currencyFormatter.format(price)}` : ''}
                        {line.default_discount_pct
                          ? ` · −${line.default_discount_pct}%`
                          : ''}
                      </p>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>

          <div>
            <h3 className="mb-2 text-sm font-semibold text-foreground">
              {t('catalog.packs.checklists_title', 'Checklists de visita')}
            </h3>
            {inspectChecklists.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('catalog.packs.no_checklists', 'Sense checklists vinculades')}
              </p>
            ) : (
              <ul className="space-y-1.5">
                {inspectChecklists.map((row) => (
                  <li
                    key={row.checklist_template_id}
                    className="rounded-md border border-border px-3 py-1.5 text-sm"
                  >
                    {checklistNameById.get(row.checklist_template_id) ??
                      row.checklist_template_id.slice(0, 8)}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </InspectorSheet>
    ) : null

  return (
    <>
      <PageShell
        bare
        inspector={inspector}
        inspectorOpen={Boolean(inspectId)}
        onInspectorClose={() => setInspectId(null)}
      >
        <div className="space-y-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2">
              <div className="relative min-w-[12rem] max-w-xs flex-1">
                <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  className="pl-9"
                  placeholder={t('catalog.search_placeholder', 'Cerca per nom...')}
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </div>
              {categories.length > 0 ? (
                <select
                  className="h-9 rounded-md border border-input bg-background px-3 text-sm"
                  value={categoryFilter ?? ''}
                  onChange={(e) => setCategoryFilter(e.target.value || null)}
                  aria-label={t('catalog.filter_category', 'Filtrar per categoria')}
                >
                  <option value="">
                    {t('catalog.filter_all_categories', 'Totes les categories')}
                  </option>
                  {categories.map((cat) => (
                    <option key={cat} value={cat}>
                      {cat}
                    </option>
                  ))}
                </select>
              ) : null}
            </div>
            <Button onClick={handleNew}>
              <Plus className="mr-1.5 h-4 w-4" />
              {t('catalog.packs.new', 'Nou servei habitual')}
            </Button>
          </div>

          {packsLoading ? (
            <div className="flex items-center justify-center py-16">
              <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
            </div>
          ) : packsError ? (
            <div className="rounded-xl border border-destructive/30 bg-destructive/10 p-4 text-center">
              <p className="text-sm font-medium text-destructive">
                {t('catalog.packs.load_failed', 'Error en carregar els serveis habituals')}
              </p>
            </div>
          ) : filteredPacks.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-3 py-16">
              <Layers className="h-10 w-10 text-muted-foreground/40" aria-hidden />
              <p className="text-sm text-muted-foreground">
                {t('catalog.packs.empty', 'Encara no hi ha serveis habituals')}
              </p>
              <Button variant="outline" size="sm" onClick={handleNew}>
                <Plus className="mr-1.5 h-4 w-4" />
                {t('catalog.packs.new', 'Nou servei habitual')}
              </Button>
            </div>
          ) : (
            <div className="overflow-hidden rounded-xl border border-border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-border bg-muted/40">
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                      {t('catalog.columns.name', 'Nom')}
                    </th>
                    <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground md:table-cell">
                      {t('catalog.columns.category', 'Categoria')}
                    </th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                      {t('catalog.packs.lines', 'Línies')}
                    </th>
                    <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground sm:table-cell">
                      {t('catalog.packs.default', 'Per defecte')}
                    </th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                      {t('catalog.columns.actions', 'Accions')}
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {filteredPacks.map((pack) => {
                    const selected = pack.id === inspectId
                    return (
                      <tr
                        key={pack.id}
                        className={`cursor-pointer transition-colors hover:bg-muted/20 ${
                          selected ? 'bg-muted/40' : ''
                        }`}
                        onClick={() =>
                          setInspectId((prev) => (prev === pack.id ? null : pack.id))
                        }
                      >
                        <td className="px-4 py-3">
                          <p className="font-medium text-foreground">{pack.name}</p>
                          {pack.description ? (
                            <p className="mt-0.5 text-xs text-muted-foreground">
                              {pack.description}
                            </p>
                          ) : null}
                        </td>
                        <td className="hidden px-4 py-3 text-muted-foreground md:table-cell">
                          {pack.category ?? '—'}
                        </td>
                        <td className="px-4 py-3 text-right tabular-nums text-foreground">
                          {packItemCounts[pack.id] ?? '…'}
                        </td>
                        <td className="hidden px-4 py-3 text-muted-foreground sm:table-cell">
                          {pack.is_default ? t('catalog.packs.yes', 'Sí') : '—'}
                        </td>
                        <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                          <div className="flex items-center justify-end gap-1.5">
                            <button
                              type="button"
                              title={t('catalog.actions.edit', 'Editar')}
                              onClick={() => handleEdit(pack)}
                              className="rounded-lg p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                            >
                              <Pencil className="h-4 w-4" />
                            </button>
                            <button
                              type="button"
                              title={t('catalog.actions.deactivate', 'Desactivar')}
                              onClick={() => void handleDeactivate(pack)}
                              className="rounded-lg p-1.5 text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
                            >
                              <PowerOff className="h-4 w-4" />
                            </button>
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </PageShell>

      <PricingTemplateForm
        open={packFormOpen}
        onClose={() => {
          setPackFormOpen(false)
          setEditPack(null)
        }}
        onSaved={() => {
          setPackFormOpen(false)
          setEditPack(null)
          queryClient.invalidateQueries({ queryKey: ['pricing_templates'] })
          if (editPack?.id) {
            queryClient.invalidateQueries({ queryKey: ['pricing_template_items', editPack.id] })
            queryClient.invalidateQueries({
              queryKey: ['pricing_template_checklists', editPack.id],
            })
          }
        }}
        template={editPack}
      />
    </>
  )
}

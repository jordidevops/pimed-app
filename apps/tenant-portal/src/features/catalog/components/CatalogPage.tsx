import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Search, Package, Pencil, PowerOff, Layers } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { getCatalogItems, deactivateCatalogItem, type CatalogItem } from '../api/catalogService'
import {
  deactivatePricingTemplate,
  listPricingTemplateItems,
  listPricingTemplates,
  type PricingTemplate,
} from '@/features/commercial/api/commercialFlowService'
import { CatalogItemForm } from './CatalogItemForm'
import { PricingTemplateForm } from './PricingTemplateForm'
import { useToast } from '@/hooks/use-toast'

type KindTab = 'service' | 'product' | 'packs'

const currencyFormatter = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

export function CatalogPage() {
  const { t } = useTranslation('catalog')
  const { activeTenant, tenantsLoading } = useTenant()
  const queryClient = useQueryClient()
  const { toast } = useToast()

  const [activeTab, setActiveTab] = useState<KindTab>('service')
  const [search, setSearch] = useState('')
  const [formOpen, setFormOpen] = useState(false)
  const [editItem, setEditItem] = useState<CatalogItem | null>(null)
  const [packFormOpen, setPackFormOpen] = useState(false)
  const [editPack, setEditPack] = useState<PricingTemplate | null>(null)
  const [packItemCounts, setPackItemCounts] = useState<Record<string, number>>({})

  const {
    data: items = [],
    isLoading,
    error,
  } = useQuery<CatalogItem[]>({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: () => getCatalogItems(),
    enabled: !!activeTenant,
  })

  const {
    data: packs = [],
    isLoading: packsLoading,
    error: packsError,
  } = useQuery({
    queryKey: ['pricing_templates', activeTenant?.id],
    queryFn: listPricingTemplates,
    enabled: !!activeTenant && activeTab === 'packs',
  })

  const filtered = useMemo(() => {
    let result = items.filter((i) => i.kind === activeTab)
    if (search.trim()) {
      const q = search.trim().toLowerCase()
      result = result.filter((i) => i.name?.toLowerCase().includes(q))
    }
    return result
  }, [items, activeTab, search])

  const filteredPacks = useMemo(() => {
    if (!search.trim()) return packs
    const q = search.trim().toLowerCase()
    return packs.filter(
      (p) =>
        p.name.toLowerCase().includes(q) ||
        (p.description ?? '').toLowerCase().includes(q) ||
        (p.category ?? '').toLowerCase().includes(q),
    )
  }, [packs, search])

  useEffect(() => {
    if (activeTab !== 'packs' || packs.length === 0) {
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
  }, [activeTab, packs])

  function handleNewItem() {
    if (activeTab === 'packs') {
      setEditPack(null)
      setPackFormOpen(true)
      return
    }
    setEditItem(null)
    setFormOpen(true)
  }

  function handleEdit(item: CatalogItem) {
    setEditItem(item)
    setFormOpen(true)
  }

  function handleEditPack(pack: PricingTemplate) {
    setEditPack(pack)
    setPackFormOpen(true)
  }

  async function handleDeactivate(item: CatalogItem) {
    if (!item.id) return
    const confirmed = window.confirm(
      t('catalog.actions.deactivate_confirm', 'Confirmes que vols desactivar aquest ítem?'),
    )
    if (!confirmed) return

    try {
      await deactivateCatalogItem(item.id)
      queryClient.invalidateQueries({ queryKey: ['catalog_items'] })
    } catch {
      toast({
        variant: 'destructive',
        title: t('catalog.errors.load_failed', 'Error en carregar el catàleg'),
      })
    }
  }

  async function handleDeactivatePack(pack: PricingTemplate) {
    const confirmed = window.confirm(
      t(
        'catalog.packs.deactivate_confirm',
        'Confirmes que vols desactivar aquest servei habitual?',
      ),
    )
    if (!confirmed) return
    try {
      await deactivatePricingTemplate(pack.id)
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

  function handleFormSaved() {
    setFormOpen(false)
    setEditItem(null)
    queryClient.invalidateQueries({ queryKey: ['catalog_items'] })
  }

  function handlePackSaved() {
    setPackFormOpen(false)
    setEditPack(null)
    queryClient.invalidateQueries({ queryKey: ['pricing_templates'] })
  }

  if (tenantsLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600" />
      </div>
    )
  }

  if (!activeTenant) return null

  const tabs: { id: KindTab; label: string }[] = [
    { id: 'service', label: t('catalog.tabs.services', 'Serveis') },
    { id: 'product', label: t('catalog.tabs.products', 'Productes') },
    { id: 'packs', label: t('catalog.tabs.packs', 'Serveis habituals') },
  ]

  return (
    <div className="max-w-6xl mx-auto px-4 py-6 space-y-5">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <Package className="h-6 w-6 text-indigo-600" aria-hidden />
          <h1 className="text-2xl font-bold text-foreground">
            {t('catalog.title', 'Catàleg')}
          </h1>
        </div>
        <Button onClick={handleNewItem}>
          <Plus className="h-4 w-4 mr-1.5" />
          {activeTab === 'packs'
            ? t('catalog.packs.new', 'Nou servei habitual')
            : t('catalog.new_item', 'Nou ítem')}
        </Button>
      </div>

      <div className="flex flex-wrap gap-1 rounded-lg border border-border p-0.5 bg-background w-fit">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            type="button"
            onClick={() => setActiveTab(tab.id)}
            className={`px-4 py-1.5 rounded-md text-sm font-medium transition-colors ${
              activeTab === tab.id
                ? 'bg-indigo-600 text-white shadow-sm'
                : 'text-muted-foreground hover:bg-accent'
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>

      <div className="relative max-w-xs">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
        <Input
          className="pl-9"
          placeholder={t('catalog.search_placeholder', 'Cerca per nom...')}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      {activeTab === 'packs' ? (
        packsLoading ? (
          <div className="flex items-center justify-center py-16">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600" />
          </div>
        ) : packsError ? (
          <div className="bg-destructive/10 border border-destructive/30 rounded-xl p-4 text-center">
            <p className="text-sm text-destructive font-medium">
              {t('catalog.packs.load_failed', 'Error en carregar els serveis habituals')}
            </p>
          </div>
        ) : filteredPacks.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-16 gap-3">
            <Layers className="h-10 w-10 text-muted-foreground/40" aria-hidden />
            <p className="text-muted-foreground text-sm">
              {t('catalog.packs.empty', 'Encara no hi ha serveis habituals')}
            </p>
            <Button variant="outline" size="sm" onClick={handleNewItem}>
              <Plus className="h-4 w-4 mr-1.5" />
              {t('catalog.packs.new', 'Nou servei habitual')}
            </Button>
          </div>
        ) : (
          <div className="rounded-xl border border-border overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border bg-muted/40">
                  <th className="text-left px-4 py-3 font-medium text-muted-foreground">
                    {t('catalog.columns.name', 'Nom')}
                  </th>
                  <th className="text-left px-4 py-3 font-medium text-muted-foreground hidden md:table-cell">
                    {t('catalog.columns.category', 'Categoria')}
                  </th>
                  <th className="text-right px-4 py-3 font-medium text-muted-foreground">
                    {t('catalog.packs.lines', 'Línies')}
                  </th>
                  <th className="text-left px-4 py-3 font-medium text-muted-foreground hidden sm:table-cell">
                    {t('catalog.packs.default', 'Per defecte')}
                  </th>
                  <th className="text-right px-4 py-3 font-medium text-muted-foreground">
                    {t('catalog.columns.actions', 'Accions')}
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {filteredPacks.map((pack) => (
                  <tr key={pack.id} className="hover:bg-muted/20 transition-colors">
                    <td className="px-4 py-3">
                      <p className="font-medium text-foreground">{pack.name}</p>
                      {pack.description ? (
                        <p className="text-xs text-muted-foreground mt-0.5">{pack.description}</p>
                      ) : null}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground hidden md:table-cell">
                      {pack.category ?? '—'}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-foreground">
                      {packItemCounts[pack.id] ?? '…'}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground hidden sm:table-cell">
                      {pack.is_default ? t('catalog.packs.yes', 'Sí') : '—'}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex items-center justify-end gap-1.5">
                        <button
                          type="button"
                          title={t('catalog.actions.edit', 'Editar')}
                          onClick={() => handleEditPack(pack)}
                          className="p-1.5 rounded-lg hover:bg-accent text-muted-foreground hover:text-foreground transition-colors"
                        >
                          <Pencil className="h-4 w-4" />
                        </button>
                        <button
                          type="button"
                          title={t('catalog.actions.deactivate', 'Desactivar')}
                          onClick={() => void handleDeactivatePack(pack)}
                          className="p-1.5 rounded-lg hover:bg-destructive/10 text-muted-foreground hover:text-destructive transition-colors"
                        >
                          <PowerOff className="h-4 w-4" />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      ) : isLoading ? (
        <div className="flex items-center justify-center py-16">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600" />
        </div>
      ) : error ? (
        <div className="bg-destructive/10 border border-destructive/30 rounded-xl p-4 text-center">
          <p className="text-sm text-destructive font-medium">
            {t('catalog.errors.load_failed', 'Error en carregar el catàleg')}
          </p>
        </div>
      ) : filtered.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-16 gap-3">
          <Package className="h-10 w-10 text-muted-foreground/40" aria-hidden />
          <p className="text-muted-foreground text-sm">
            {activeTab === 'service'
              ? t('catalog.empty_services', 'No hi ha serveis al catàleg')
              : t('catalog.empty_products', 'No hi ha productes al catàleg')}
          </p>
          <Button variant="outline" size="sm" onClick={handleNewItem}>
            <Plus className="h-4 w-4 mr-1.5" />
            {t('catalog.new_item', 'Nou ítem')}
          </Button>
        </div>
      ) : (
        <div className="rounded-xl border border-border overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/40">
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">
                  {t('catalog.columns.name', 'Nom')}
                </th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground hidden sm:table-cell">
                  {t('catalog.columns.sku', 'SKU')}
                </th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground hidden md:table-cell">
                  {t('catalog.columns.unit', 'Unitat')}
                </th>
                <th className="text-right px-4 py-3 font-medium text-muted-foreground">
                  {t('catalog.columns.unit_price', 'Preu unit.')}
                </th>
                <th className="text-right px-4 py-3 font-medium text-muted-foreground hidden sm:table-cell">
                  {t('catalog.columns.tax_rate', 'IVA')}
                </th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground hidden lg:table-cell">
                  {t('catalog.columns.category', 'Categoria')}
                </th>
                <th className="text-right px-4 py-3 font-medium text-muted-foreground">
                  {t('catalog.columns.actions', 'Accions')}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {filtered.map((item) => (
                <tr key={item.id} className="hover:bg-muted/20 transition-colors">
                  <td className="px-4 py-3 font-medium text-foreground">{item.name}</td>
                  <td className="px-4 py-3 text-muted-foreground hidden sm:table-cell font-mono text-xs">
                    {item.sku ?? '—'}
                  </td>
                  <td className="px-4 py-3 text-muted-foreground hidden md:table-cell">
                    {item.unit ? t(`catalog.units.${item.unit}`, item.unit) : '—'}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-foreground">
                    {item.unit_price != null
                      ? currencyFormatter.format(item.unit_price)
                      : '—'}
                  </td>
                  <td className="px-4 py-3 text-right text-muted-foreground hidden sm:table-cell">
                    {item.tax_rate != null ? `${item.tax_rate}%` : '—'}
                  </td>
                  <td className="px-4 py-3 text-muted-foreground hidden lg:table-cell text-sm">
                    {item.category ?? '—'}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <div className="flex items-center justify-end gap-1.5">
                      <button
                        type="button"
                        title={t('catalog.actions.edit', 'Editar')}
                        onClick={() => handleEdit(item)}
                        className="p-1.5 rounded-lg hover:bg-accent text-muted-foreground hover:text-foreground transition-colors"
                      >
                        <Pencil className="h-4 w-4" />
                      </button>
                      <button
                        type="button"
                        title={t('catalog.actions.deactivate', 'Desactivar')}
                        onClick={() => void handleDeactivate(item)}
                        className="p-1.5 rounded-lg hover:bg-destructive/10 text-muted-foreground hover:text-destructive transition-colors"
                      >
                        <PowerOff className="h-4 w-4" />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <CatalogItemForm
        open={formOpen}
        onClose={() => {
          setFormOpen(false)
          setEditItem(null)
        }}
        onSaved={handleFormSaved}
        item={editItem}
      />

      <PricingTemplateForm
        open={packFormOpen}
        onClose={() => {
          setPackFormOpen(false)
          setEditPack(null)
        }}
        onSaved={handlePackSaved}
        template={editPack}
      />
    </div>
  )
}

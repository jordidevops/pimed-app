import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useLocation } from 'react-router-dom'
import { Package, Pencil, Plus, PowerOff, Search } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { getCatalogItems, deactivateCatalogItem, type CatalogItem } from '../api/catalogService'
import { CatalogItemForm } from './CatalogItemForm'
import { useToast } from '@/hooks/use-toast'

const currencyFormatter = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

function useCatalogKind(): 'service' | 'product' {
  const { pathname } = useLocation()
  return pathname.startsWith('/catalog/products') ? 'product' : 'service'
}

export function CatalogItemsPage() {
  const { t } = useTranslation('catalog')
  const kind = useCatalogKind()
  const { activeTenant, tenantsLoading } = useTenant()
  const queryClient = useQueryClient()
  const { toast } = useToast()

  const [search, setSearch] = useState('')
  const [categoryFilter, setCategoryFilter] = useState<string | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [editItem, setEditItem] = useState<CatalogItem | null>(null)

  useEffect(() => {
    setSearch('')
    setCategoryFilter(null)
    setFormOpen(false)
    setEditItem(null)
  }, [kind])

  const {
    data: items = [],
    isLoading,
    error,
  } = useQuery<CatalogItem[]>({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: () => getCatalogItems(),
    enabled: !!activeTenant,
  })

  const kindItems = useMemo(
    () => items.filter((i) => i.kind === kind),
    [items, kind],
  )

  const categories = useMemo(() => {
    const set = new Set<string>()
    for (const item of kindItems) {
      if (item.category?.trim()) set.add(item.category.trim())
    }
    return Array.from(set).sort((a, b) => a.localeCompare(b, 'ca'))
  }, [kindItems])

  const filtered = useMemo(() => {
    let result = kindItems
    if (categoryFilter) {
      result = result.filter((i) => (i.category ?? '').trim() === categoryFilter)
    }
    if (search.trim()) {
      const q = search.trim().toLowerCase()
      result = result.filter(
        (i) =>
          i.name?.toLowerCase().includes(q) ||
          (i.sku ?? '').toLowerCase().includes(q) ||
          (i.category ?? '').toLowerCase().includes(q),
      )
    }
    return result
  }, [kindItems, categoryFilter, search])

  function handleNewItem() {
    setEditItem(null)
    setFormOpen(true)
  }

  function handleEdit(item: CatalogItem) {
    setEditItem(item)
    setFormOpen(true)
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

  if (tenantsLoading) {
    return (
      <div className="flex h-48 items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (!activeTenant) return null

  return (
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
              <option value="">{t('catalog.filter_all_categories', 'Totes les categories')}</option>
              {categories.map((cat) => (
                <option key={cat} value={cat}>
                  {cat}
                </option>
              ))}
            </select>
          ) : null}
        </div>
        <Button onClick={handleNewItem}>
          <Plus className="mr-1.5 h-4 w-4" />
          {t('catalog.new_item', 'Nou ítem')}
        </Button>
      </div>

      {isLoading ? (
        <div className="flex items-center justify-center py-16">
          <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
        </div>
      ) : error ? (
        <div className="rounded-xl border border-destructive/30 bg-destructive/10 p-4 text-center">
          <p className="text-sm font-medium text-destructive">
            {t('catalog.errors.load_failed', 'Error en carregar el catàleg')}
          </p>
        </div>
      ) : filtered.length === 0 ? (
        <div className="flex flex-col items-center justify-center gap-3 py-16">
          <Package className="h-10 w-10 text-muted-foreground/40" aria-hidden />
          <p className="text-sm text-muted-foreground">
            {kind === 'service'
              ? t('catalog.empty_services', 'No hi ha serveis al catàleg')
              : t('catalog.empty_products', 'No hi ha productes al catàleg')}
          </p>
          <Button variant="outline" size="sm" onClick={handleNewItem}>
            <Plus className="mr-1.5 h-4 w-4" />
            {t('catalog.new_item', 'Nou ítem')}
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
                <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground sm:table-cell">
                  {t('catalog.columns.sku', 'SKU')}
                </th>
                <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground md:table-cell">
                  {t('catalog.columns.unit', 'Unitat')}
                </th>
                <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                  {t('catalog.columns.unit_price', 'Preu unit.')}
                </th>
                <th className="hidden px-4 py-3 text-right font-medium text-muted-foreground sm:table-cell">
                  {t('catalog.columns.tax_rate', 'IVA')}
                </th>
                <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground lg:table-cell">
                  {t('catalog.columns.category', 'Categoria')}
                </th>
                <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                  {t('catalog.columns.actions', 'Accions')}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {filtered.map((item) => (
                <tr key={item.id} className="transition-colors hover:bg-muted/20">
                  <td className="px-4 py-3 font-medium text-foreground">{item.name}</td>
                  <td className="hidden px-4 py-3 font-mono text-xs text-muted-foreground sm:table-cell">
                    {item.sku ?? '—'}
                  </td>
                  <td className="hidden px-4 py-3 text-muted-foreground md:table-cell">
                    {item.unit ? t(`catalog.units.${item.unit}`, item.unit) : '—'}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-foreground">
                    {item.unit_price != null
                      ? currencyFormatter.format(item.unit_price)
                      : '—'}
                  </td>
                  <td className="hidden px-4 py-3 text-right text-muted-foreground sm:table-cell">
                    {item.tax_rate != null ? `${item.tax_rate}%` : '—'}
                  </td>
                  <td className="hidden px-4 py-3 text-sm text-muted-foreground lg:table-cell">
                    {item.category ?? '—'}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <div className="flex items-center justify-end gap-1.5">
                      <button
                        type="button"
                        title={t('catalog.actions.edit', 'Editar')}
                        onClick={() => handleEdit(item)}
                        className="rounded-lg p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                      >
                        <Pencil className="h-4 w-4" />
                      </button>
                      <button
                        type="button"
                        title={t('catalog.actions.deactivate', 'Desactivar')}
                        onClick={() => void handleDeactivate(item)}
                        className="rounded-lg p-1.5 text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
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
        onSaved={() => {
          setFormOpen(false)
          setEditItem(null)
          queryClient.invalidateQueries({ queryKey: ['catalog_items'] })
        }}
        item={editItem}
        defaultKind={kind}
      />
    </div>
  )
}

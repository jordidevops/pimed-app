import { useEffect, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  centsToEuros,
  createCatalogItem,
  eurosToCents,
  getCatalogItemFinancials,
  marginBpsToPercent,
  percentToMarginBps,
  setCatalogItemFinancials,
  suggestPvpEurosFromCost,
  updateCatalogItem,
  type CatalogItem,
} from '../api/catalogService'
import { unitSelectOptions } from '../unitOptions'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'

const catalogItemSchema = z.object({
  kind: z.enum(['service', 'product']),
  name: z.string().min(1, 'errors.name_required'),
  description: z.string().optional(),
  sku: z.string().optional(),
  unit: z.string().optional(),
  unit_price: z.number().min(0, 'errors.price_invalid'),
  tax_rate: z.number(),
  category: z.string().optional(),
})

type CatalogItemFormValues = z.infer<typeof catalogItemSchema>

interface CatalogItemFormProps {
  open: boolean
  onClose: () => void
  onSaved: () => void
  item?: CatalogItem | null
  defaultKind?: 'service' | 'product'
}

const TAX_RATE_OPTIONS = [0, 4, 10, 21] as const

export function CatalogItemForm({
  open,
  onClose,
  onSaved,
  item,
  defaultKind = 'service',
}: CatalogItemFormProps) {
  const { t } = useTranslation('catalog')
  const { toast } = useToast()
  const canSeeCost = usePermission('commercial.costs.view', null)
  const canEditPricing = usePermission('commercial.pricing.edit', null)
  const [costEuros, setCostEuros] = useState('')
  const [marginPercent, setMarginPercent] = useState('')
  const [financialsLoaded, setFinancialsLoaded] = useState(false)
  const [financialsDirty, setFinancialsDirty] = useState(false)
  const [financialsLoadFailed, setFinancialsLoadFailed] = useState(false)

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<CatalogItemFormValues>({
    resolver: zodResolver(catalogItemSchema),
    defaultValues: {
      kind: defaultKind,
      name: '',
      description: '',
      sku: '',
      unit: 'u',
      unit_price: 0,
      tax_rate: 21,
      category: '',
    },
  })

  useEffect(() => {
    if (!open) return
    if (item) {
      reset({
        kind: item.kind ?? defaultKind,
        name: item.name ?? '',
        description: item.description ?? '',
        sku: item.sku ?? '',
        unit: item.unit ?? 'u',
        unit_price: item.unit_price ?? 0,
        tax_rate: item.tax_rate ?? 21,
        category: item.category ?? '',
      })
    } else {
      reset({
        kind: defaultKind,
        name: '',
        description: '',
        sku: '',
        unit: 'u',
        unit_price: 0,
        tax_rate: 21,
        category: '',
      })
    }
    setCostEuros('')
    setMarginPercent('')
    setFinancialsLoaded(false)
    setFinancialsDirty(false)
    setFinancialsLoadFailed(false)
  }, [open, item, defaultKind, reset])

  useEffect(() => {
    if (!open || !canSeeCost || !item?.id) {
      setFinancialsLoaded(true)
      setFinancialsLoadFailed(false)
      return
    }
    let cancelled = false
    void getCatalogItemFinancials(item.id)
      .then((row) => {
        if (cancelled) return
        if (row) {
          setCostEuros(centsToEuros(row.unit_cost_cents))
          setMarginPercent(marginBpsToPercent(row.target_margin_bps))
        }
        setFinancialsLoadFailed(false)
        setFinancialsLoaded(true)
      })
      .catch(() => {
        if (!cancelled) {
          setFinancialsLoadFailed(true)
          setFinancialsLoaded(true)
        }
      })
    return () => {
      cancelled = true
    }
  }, [open, canSeeCost, item?.id])

  const kind = watch('kind')
  const unit = watch('unit')
  const unitOptions = unitSelectOptions(unit)

  function handleSuggestPvp() {
    const cents = eurosToCents(costEuros)
    const bps = percentToMarginBps(marginPercent)
    if (cents == null || bps == null) {
      toast({
        variant: 'destructive',
        title: t(
          'catalog.form.suggest_pvp_need_cost_margin',
          'Cal cost i marge (0–99%) per suggerir el PVP',
        ),
      })
      return
    }
    const suggested = suggestPvpEurosFromCost(cents, bps)
    if (suggested == null) {
      toast({
        variant: 'destructive',
        title: t('catalog.form.suggest_pvp_failed', 'No s’ha pogut calcular el PVP'),
      })
      return
    }
    setValue('unit_price', suggested, { shouldDirty: true, shouldValidate: true })
  }

  async function onSubmit(values: CatalogItemFormValues) {
    try {
      let itemId = item?.id ?? null
      if (itemId) {
        await updateCatalogItem(itemId, {
          kind: values.kind,
          name: values.name,
          description: values.description || null,
          sku: values.sku || null,
          unit: values.unit || null,
          unit_price: values.unit_price,
          tax_rate: values.tax_rate,
          category: values.category || null,
        })
      } else {
        itemId = await createCatalogItem({
          p_kind: values.kind,
          p_name: values.name,
          p_description: values.description || undefined,
          p_sku: values.sku || undefined,
          p_unit: values.unit || undefined,
          p_unit_price: values.unit_price,
          p_tax_rate: values.tax_rate,
          p_category: values.category || undefined,
        })
      }

      if (canSeeCost && itemId && financialsDirty) {
        if (financialsLoadFailed && item?.id) {
          toast({
            variant: 'destructive',
            title: t(
              'catalog.form.financials_load_failed',
              'No s’han pogut carregar els costos; no s’han modificat',
            ),
          })
          return
        }
        const costTrim = costEuros.trim()
        const marginTrim = marginPercent.trim()
        if (!costTrim && !marginTrim) {
          await setCatalogItemFinancials(itemId, { unit_cost_cents: null })
        } else if (!costTrim) {
          toast({
            variant: 'destructive',
            title: t(
              'catalog.form.cost_required_for_margin',
              'El marge requereix un cost unitari',
            ),
          })
          return
        } else {
          const cents = eurosToCents(costTrim)
          if (cents == null) {
            toast({
              variant: 'destructive',
              title: t('catalog.form.cost_invalid', 'Cost no vàlid'),
            })
            return
          }
          let bps: number | null = null
          if (marginTrim) {
            bps = percentToMarginBps(marginTrim)
            if (bps == null) {
              toast({
                variant: 'destructive',
                title: t('catalog.form.margin_invalid', 'Marge no vàlid (0–99%)'),
              })
              return
            }
          }
          await setCatalogItemFinancials(itemId, {
            unit_cost_cents: cents,
            target_margin_bps: bps,
          })
        }
      }

      toast({ title: t('catalog.form.save', 'Desar') })
      reset()
      onSaved()
    } catch {
      toast({
        variant: 'destructive',
        title: t('catalog.errors.load_failed', 'Error en carregar el catàleg'),
      })
    }
  }

  function handleClose() {
    reset()
    onClose()
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) handleClose() }}>
      <DialogContent className="sm:max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {item
              ? t('catalog.form.title_edit', 'Editar ítem')
              : t('catalog.form.title_create', 'Nou ítem de catàleg')}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 pt-2">
          <div>
            <label className="text-sm font-medium text-foreground block mb-1.5">
              {t('catalog.form.kind_label', 'Tipus')}
            </label>
            <div className="flex gap-2">
              {(['service', 'product'] as const).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => setValue('kind', k)}
                  className={`flex-1 py-2 rounded-lg border text-sm font-medium transition-colors ${
                    kind === k
                      ? 'bg-indigo-600 text-white border-indigo-600'
                      : 'border-border text-muted-foreground hover:bg-accent'
                  }`}
                >
                  {k === 'service'
                    ? t('catalog.form.kind_service', 'Servei')
                    : t('catalog.form.kind_product', 'Producte')}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-sm font-medium text-foreground block mb-1.5">
              {t('catalog.form.name_label', 'Nom')}
              <span className="text-destructive ml-1">*</span>
            </label>
            <Input {...register('name')} />
            {errors.name && (
              <p className="text-destructive text-xs mt-1">
                {t('catalog.errors.name_required', 'El nom és obligatori')}
              </p>
            )}
          </div>

          <div>
            <label className="text-sm font-medium text-foreground block mb-1.5">
              {t('catalog.form.description_label', 'Descripció')}
            </label>
            <textarea
              {...register('description')}
              rows={2}
              className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring resize-none"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium text-foreground block mb-1.5">
                {t('catalog.form.sku_label', 'SKU / Referència')}
              </label>
              <Input {...register('sku')} />
            </div>
            <div>
              <label className="text-sm font-medium text-foreground block mb-1.5">
                {t('catalog.form.unit_label', 'Unitat')}
              </label>
              <select
                {...register('unit')}
                className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
              >
                {unitOptions.map((u) => (
                  <option key={u} value={u}>
                    {t(`catalog.units.${u}`, u)}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium text-foreground block mb-1.5">
                {t('catalog.form.unit_price_label', 'Preu unitari (€)')}
                <span className="text-destructive ml-1">*</span>
              </label>
              <Input
                type="number"
                step="0.01"
                min="0"
                disabled={!canEditPricing && !!item}
                {...register('unit_price', { valueAsNumber: true })}
              />
              {errors.unit_price && (
                <p className="text-destructive text-xs mt-1">
                  {t('catalog.errors.price_invalid', 'El preu ha de ser 0 o superior')}
                </p>
              )}
            </div>
            <div>
              <label className="text-sm font-medium text-foreground block mb-1.5">
                {t('catalog.form.tax_rate_label', 'IVA (%)')}
              </label>
              <select
                {...register('tax_rate', { valueAsNumber: true })}
                className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
              >
                {TAX_RATE_OPTIONS.map((rate) => (
                  <option key={rate} value={rate}>
                    {rate}%
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div>
            <label className="text-sm font-medium text-foreground block mb-1.5">
              {t('catalog.form.category_label', 'Categoria')}
            </label>
            <Input {...register('category')} />
          </div>

          {canSeeCost && financialsLoaded ? (
            <div className="space-y-3 rounded-lg border border-border p-3">
              <p className="text-sm font-medium text-foreground">
                {t('catalog.form.financials_title', 'Costos privats')}
              </p>
              <p className="text-xs text-muted-foreground">
                {t(
                  'catalog.form.financials_hint',
                  'Només visible amb permís financer. El marge és sobre el preu de venda.',
                )}
              </p>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="text-sm font-medium text-foreground block mb-1.5">
                    {t('catalog.form.unit_cost_label', 'Cost unitari (€)')}
                  </label>
                  <Input
                    inputMode="decimal"
                    value={costEuros}
                    onChange={(e) => {
                      setCostEuros(e.target.value)
                      setFinancialsDirty(true)
                    }}
                    placeholder="0.00"
                  />
                </div>
                <div>
                  <label className="text-sm font-medium text-foreground block mb-1.5">
                    {t('catalog.form.target_margin_label', 'Marge objectiu (%)')}
                  </label>
                  <Input
                    inputMode="decimal"
                    value={marginPercent}
                    onChange={(e) => {
                      setMarginPercent(e.target.value)
                      setFinancialsDirty(true)
                    }}
                    placeholder="0–99"
                  />
                </div>
              </div>
              {canEditPricing ? (
                <Button type="button" variant="outline" size="sm" onClick={handleSuggestPvp}>
                  {t('catalog.form.suggest_pvp', 'Suggerir PVP')}
                </Button>
              ) : null}
            </div>
          ) : null}

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={handleClose} disabled={isSubmitting}>
              {t('catalog.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('catalog.form.saving', 'Desant...')
                : t('catalog.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}

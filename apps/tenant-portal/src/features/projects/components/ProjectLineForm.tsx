import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { getCatalogItems, type CatalogItem } from '@/features/catalog/api/catalogService'
import {
  DISCOUNT_CHIPS,
  formatQuantityChip,
  quantityChipsForUnit,
  unitSelectOptions,
} from '@/features/catalog/unitOptions'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { usePermission } from '@/hooks/usePermission'
import { usePriceSheetTitle } from '@/hooks/useSectorLabel'
import { priceSheetRpcErrorCopy, priceSheetRpcErrorTitle } from '@/features/commercial/utils/rpcError'
import type { Database } from '@/types/database.types'

type ProjectLine = Database['api']['Views']['project_lines']['Row']

// ─── Schema ───────────────────────────────────────────────────────────────────

const lineSchema = z.object({
  catalog_item_id: z.string().optional(),
  kind: z.enum(['service', 'product']),
  name: z.string().min(1),
  unit: z.string().optional(),
  quantity: z.number().min(0),
  unit_price: z.number().min(0),
  discount_pct: z.number().min(0).max(100),
  tax_rate: z.number(),
  notes: z.string().optional(),
})

type LineFormValues = z.infer<typeof lineSchema>

// ─── Props ────────────────────────────────────────────────────────────────────

interface ProjectLineFormProps {
  projectId: string
  line?: ProjectLine | null
  onSaved: () => void
  onCancel: () => void
}

const TAX_RATE_OPTIONS = [0, 4, 10, 21] as const

// ─── Preview helpers ──────────────────────────────────────────────────────────

function calcSubtotal(qty: number, price: number, discount: number): number {
  return qty * price * (1 - discount / 100)
}

function calcTotal(subtotal: number, taxRate: number): number {
  return subtotal * (1 + taxRate / 100)
}

const moneyFmt = new Intl.NumberFormat('ca-ES', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// ─── ProjectLineForm ──────────────────────────────────────────────────────────

export function ProjectLineForm({ projectId, line, onSaved, onCancel }: ProjectLineFormProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const priceSheetTitle = usePriceSheetTitle()

  const { data: catalogItems = [] } = useQuery<CatalogItem[]>({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: () => getCatalogItems(),
    enabled: !!activeTenant,
  })

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<LineFormValues>({
    resolver: zodResolver(lineSchema),
    defaultValues: line
      ? {
          catalog_item_id: line.catalog_item_id ?? undefined,
          kind: line.kind ?? 'service',
          name: line.name ?? '',
          unit: line.unit ?? 'u',
          quantity: line.quantity ?? 1,
          unit_price: line.unit_price ?? 0,
          discount_pct: line.discount_pct ?? 0,
          tax_rate: line.tax_rate ?? 21,
          notes: line.notes ?? '',
        }
      : {
          kind: 'service',
          name: '',
          unit: 'u',
          quantity: 1,
          unit_price: 0,
          discount_pct: 0,
          tax_rate: 21,
          notes: '',
        },
  })

  const watchedValues = watch()
  const unitOptions = unitSelectOptions(watchedValues.unit)
  const quantityChips = quantityChipsForUnit(watchedValues.unit)
  const subtotal = calcSubtotal(
    watchedValues.quantity ?? 0,
    watchedValues.unit_price ?? 0,
    watchedValues.discount_pct ?? 0,
  )
  const totalWithTax = calcTotal(subtotal, watchedValues.tax_rate ?? 0)

  // ─── Catalog item selection ───────────────────────────────────────────────

  function handleCatalogItemChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const selectedId = e.target.value
    setValue('catalog_item_id', selectedId || undefined)
    if (selectedId) {
      const found = catalogItems.find((ci) => ci.id === selectedId)
      if (found) {
        if (found.name) setValue('name', found.name)
        if (found.unit) setValue('unit', found.unit)
        if (found.unit_price != null) setValue('unit_price', found.unit_price)
        if (found.tax_rate != null) setValue('tax_rate', found.tax_rate)
        if (found.kind) setValue('kind', found.kind)
      }
    }
  }

  // ─── Submit ───────────────────────────────────────────────────────────────

  async function onSubmit(values: LineFormValues) {
    if (!canEditPricing && !values.catalog_item_id) {
      toast({
        variant: 'destructive',
        title: t(
          'projects.lines.errors.pricing_denied_title',
          'No es pot canviar el preu',
        ),
        description: t(
          'projects.lines.errors.catalog_required_help',
          'Sense permís de preus cal triar un ítem del catàleg (PVP). No es poden crear línies lliures.',
        ),
      })
      return
    }
    try {
      const { supabase } = await import('@/lib/supabase')
      const params = {
        p_project_id: projectId,
        p_line_id: line?.id ?? undefined,
        p_catalog_item_id: values.catalog_item_id ?? undefined,
        p_kind: values.kind,
        p_name: values.name,
        p_description: undefined as string | undefined,
        p_unit: values.unit ?? 'u',
        p_quantity: values.quantity,
        p_unit_price: values.unit_price,
        p_discount_pct: values.discount_pct,
        p_tax_rate: values.tax_rate,
        p_position: undefined as number | undefined,
        p_notes: values.notes ?? undefined,
        p_client_op_id: line?.id ? undefined : generateClientOpId(),
      }
      const { error } = await supabase.rpc('upsert_project_line', params)
      if (error) throw error
      onSaved()
    } catch (err) {
      const copy = priceSheetRpcErrorCopy(err, priceSheetTitle)
      toast({
        variant: 'destructive',
        title: priceSheetRpcErrorTitle(t, copy),
        description: t(copy.descriptionKey, copy.descriptionFallback),
      })
    }
  }

  // ─── Render ───────────────────────────────────────────────────────────────

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      <h3 className="text-base font-semibold text-foreground">
        {line
          ? t('projects.lines.form.title_edit', 'Editar línia')
          : t('projects.lines.form.title_add', 'Afegir línia')}
      </h3>

      {/* Catalog item selector */}
      <div>
        <label htmlFor="pf-catalog-item" className="text-sm font-medium text-foreground block mb-1.5">
          {t('projects.lines.form.catalog_item_label', 'Ítem del catàleg')}
        </label>
        <select
          id="pf-catalog-item"
          value={watchedValues.catalog_item_id ?? ''}
          onChange={handleCatalogItemChange}
          className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
        >
          <option value="">
            {canEditPricing
              ? t(
                  'projects.lines.form.catalog_item_placeholder',
                  'Selecciona o escriu per cercar...',
                )
              : t(
                  'projects.lines.form.catalog_item_required',
                  'Selecciona un ítem del catàleg (obligatori)',
                )}
          </option>
          {catalogItems.map((ci) => (
            <option key={ci.id} value={ci.id ?? ''}>
              {ci.name} {ci.sku ? `(${ci.sku})` : ''}
            </option>
          ))}
        </select>
        {!canEditPricing ? (
          <p className="mt-1 text-xs text-muted-foreground">
            {t(
              'projects.lines.form.catalog_required_hint',
              'Sense permís de preus només pots afegir ítems del catàleg al PVP.',
            )}
          </p>
        ) : null}
      </div>

      {/* Kind + Name row */}
      <div className="grid grid-cols-3 gap-3">
        <div>
          <label htmlFor="pf-kind" className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.columns.name', 'Descripció')}
          </label>
          <select
            id="pf-kind"
            {...register('kind')}
            className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
          >
            <option value="service">{t('projects.lines.form.kind_service', 'Servei')}</option>
            <option value="product">{t('projects.lines.form.kind_product', 'Producte')}</option>
          </select>
        </div>
        <div className="col-span-2">
          <label className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.name_label', 'Descripció')}
            <span className="text-destructive ml-1">*</span>
          </label>
          <Input {...register('name')} />
          {errors.name && (
            <p className="text-destructive text-xs mt-1">
              {t('projects.lines.form.name_label', 'Descripció')}
            </p>
          )}
        </div>
      </div>

      {/* Quantity + Unit + Price row */}
      <div className="grid grid-cols-3 gap-3">
        <div>
          <label className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.quantity_label', 'Quantitat')}
          </label>
          <Input type="number" step="0.01" min="0" {...register('quantity', { valueAsNumber: true })} />
          {quantityChips.length > 0 && (
            <div className="mt-1.5 flex flex-wrap gap-1">
              {quantityChips.map((q) => (
                <button
                  key={q}
                  type="button"
                  onClick={() => setValue('quantity', q, { shouldDirty: true, shouldValidate: true })}
                  className={`rounded-md border px-2 py-0.5 text-xs tabular-nums transition-colors ${
                    watchedValues.quantity === q
                      ? 'border-primary bg-primary/10 text-primary'
                      : 'border-border text-muted-foreground hover:bg-accent'
                  }`}
                >
                  {formatQuantityChip(q)}
                  {watchedValues.unit ? ` ${watchedValues.unit}` : ''}
                </button>
              ))}
            </div>
          )}
        </div>
        <div>
          <label htmlFor="pf-unit" className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.unit_label', 'Unitat')}
          </label>
          <select
            id="pf-unit"
            {...register('unit')}
            className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
          >
            {unitOptions.map((u) => (
              <option key={u} value={u}>
                {u}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.unit_price_label', 'Preu unitari')}
          </label>
          <Input
            type="number"
            step="0.01"
            min="0"
            disabled={!canEditPricing}
            {...register('unit_price', { valueAsNumber: true })}
          />
          {!canEditPricing && (
            <p className="mt-1 text-xs text-muted-foreground">
              {t(
                'projects.lines.form.pricing_locked',
                'Només l’oficina pot canviar preus, descompte i IVA.',
              )}
            </p>
          )}
        </div>
      </div>

      {/* Discount + Tax rate */}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.discount_label', 'Descompte (%)')}
          </label>
          <Input
            type="number"
            step="0.01"
            min="0"
            max="100"
            disabled={!canEditPricing}
            {...register('discount_pct', { valueAsNumber: true })}
          />
          {canEditPricing && (
            <div className="mt-1.5 flex flex-wrap gap-1">
              {DISCOUNT_CHIPS.map((d) => (
                <button
                  key={d}
                  type="button"
                  onClick={() => setValue('discount_pct', d, { shouldDirty: true, shouldValidate: true })}
                  className={`rounded-md border px-2 py-0.5 text-xs tabular-nums transition-colors ${
                    watchedValues.discount_pct === d
                      ? 'border-primary bg-primary/10 text-primary'
                      : 'border-border text-muted-foreground hover:bg-accent'
                  }`}
                >
                  {d}%
                </button>
              ))}
            </div>
          )}
        </div>
        <div>
          <label htmlFor="pf-tax-rate" className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.tax_rate_label', 'IVA (%)')}
          </label>
          <select
            id="pf-tax-rate"
            disabled={!canEditPricing}
            {...register('tax_rate', { valueAsNumber: true })}
            className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-60"
          >
            {TAX_RATE_OPTIONS.map((rate) => (
              <option key={rate} value={rate}>
                {rate}%
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Notes */}
      <div>
        <label className="text-sm font-medium text-foreground block mb-1.5">
          {t('projects.lines.form.notes_label', 'Notes')}
        </label>
        <textarea
          {...register('notes')}
          rows={2}
          className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring resize-none"
        />
      </div>

      {/* Real-time preview */}
      <div className="rounded-lg bg-muted/40 border border-border px-4 py-3 space-y-1">
        <div className="flex justify-between text-sm text-muted-foreground">
          <span>{t('projects.lines.form.preview_subtotal', 'Subtotal: {{amount}} €').replace('{{amount}}', '')}</span>
          <span className="font-medium text-foreground tabular-nums">
            {moneyFmt.format(subtotal)} €
          </span>
        </div>
        <div className="flex justify-between text-sm font-semibold text-foreground">
          <span>{t('projects.lines.form.preview_total', 'Total (amb IVA): {{amount}} €').replace('{{amount}}', '')}</span>
          <span className="tabular-nums">{moneyFmt.format(totalWithTax)} €</span>
        </div>
      </div>

      {/* Actions */}
      <div className="flex justify-end gap-2 pt-1">
        <Button type="button" variant="outline" onClick={onCancel} disabled={isSubmitting}>
          {t('projects.lines.form.cancel', 'Cancel·lar')}
        </Button>
        <Button type="submit" disabled={isSubmitting}>
          {t('projects.lines.form.save', 'Desar')}
        </Button>
      </div>
    </form>
  )
}

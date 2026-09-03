import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { getCatalogItems, type CatalogItem } from '@/features/catalog/api/catalogService'
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

const UNIT_OPTIONS = ['u', 'h', 'm2', 'm', 'kg', 'visita', 'dia', 'm3'] as const
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
  const { activeTenant } = useTenant()

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
    }
    const { error } = await supabase.rpc('upsert_project_line', params)
    if (error) throw error
    onSaved()
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
            {t('projects.lines.form.catalog_item_placeholder', 'Selecciona o escriu per cercar...')}
          </option>
          {catalogItems.map((ci) => (
            <option key={ci.id} value={ci.id ?? ''}>
              {ci.name} {ci.sku ? `(${ci.sku})` : ''}
            </option>
          ))}
        </select>
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
            {UNIT_OPTIONS.map((u) => (
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
          <Input type="number" step="0.01" min="0" {...register('unit_price', { valueAsNumber: true })} />
        </div>
      </div>

      {/* Discount + Tax rate */}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.discount_label', 'Descompte (%)')}
          </label>
          <Input type="number" step="0.01" min="0" max="100" {...register('discount_pct', { valueAsNumber: true })} />
        </div>
        <div>
          <label htmlFor="pf-tax-rate" className="text-sm font-medium text-foreground block mb-1.5">
            {t('projects.lines.form.tax_rate_label', 'IVA (%)')}
          </label>
          <select
            id="pf-tax-rate"
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

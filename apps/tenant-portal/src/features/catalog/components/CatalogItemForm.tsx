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
import { createCatalogItem, updateCatalogItem, type CatalogItem } from '../api/catalogService'
import { unitSelectOptions } from '../unitOptions'
import { useToast } from '@/hooks/use-toast'

// ─── Schema ───────────────────────────────────────────────────────────────────

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

// ─── Props ────────────────────────────────────────────────────────────────────

interface CatalogItemFormProps {
  open: boolean
  onClose: () => void
  onSaved: () => void
  item?: CatalogItem | null
}

const TAX_RATE_OPTIONS = [0, 4, 10, 21] as const

// ─── CatalogItemForm ──────────────────────────────────────────────────────────

export function CatalogItemForm({ open, onClose, onSaved, item }: CatalogItemFormProps) {
  const { t } = useTranslation('catalog')
  const { toast } = useToast()

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<CatalogItemFormValues>({
    resolver: zodResolver(catalogItemSchema),
    defaultValues: item
      ? {
          kind: item.kind ?? 'service',
          name: item.name ?? '',
          description: item.description ?? '',
          sku: item.sku ?? '',
          unit: item.unit ?? 'u',
          unit_price: item.unit_price ?? 0,
          tax_rate: item.tax_rate ?? 21,
          category: item.category ?? '',
        }
      : {
          kind: 'service',
          name: '',
          description: '',
          sku: '',
          unit: 'u',
          unit_price: 0,
          tax_rate: 21,
          category: '',
        },
  })

  const kind = watch('kind')
  const unit = watch('unit')
  const unitOptions = unitSelectOptions(unit)

  async function onSubmit(values: CatalogItemFormValues) {
    try {
      if (item?.id) {
        await updateCatalogItem(item.id, {
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
        await createCatalogItem({
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
          {/* Kind */}
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

          {/* Name */}
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

          {/* Description */}
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

          {/* SKU + Unit in a row */}
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

          {/* Unit price + Tax rate in a row */}
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

          {/* Category */}
          <div>
            <label className="text-sm font-medium text-foreground block mb-1.5">
              {t('catalog.form.category_label', 'Categoria')}
            </label>
            <Input {...register('category')} />
          </div>

          {/* Actions */}
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

import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import {
  DISCOUNT_CHIPS,
  formatQuantityChip,
  quantityChipsForUnit,
} from '@/features/catalog/unitOptions'
import { getCatalogItems } from '@/features/catalog/api/catalogService'
import { useTenant } from '@/contexts/TenantContext'
import {
  applyPricingTemplate,
  listPricingTemplateItems,
  listPricingTemplates,
  type PricingTemplate,
} from '../api/commercialFlowService'
import {
  isCommercialPricingPermissionDenied,
  rpcErrorMessage,
} from '../utils/rpcError'

interface ApplyPricingTemplateDialogProps {
  projectId: string
  open: boolean
  onClose: () => void
  onApplied: () => void
  initialTemplateId?: string | null
}

export function ApplyPricingTemplateDialog({
  projectId,
  open,
  onClose,
  onApplied,
  initialTemplateId,
}: ApplyPricingTemplateDialogProps) {
  const { t } = useTranslation(['projects', 'catalog'])
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const [templateId, setTemplateId] = useState(initialTemplateId ?? '')
  const [quantities, setQuantities] = useState<Record<string, number>>({})
  const [discountPct, setDiscountPct] = useState(0)
  const [submitting, setSubmitting] = useState(false)

  const { data: templates = [] } = useQuery({
    queryKey: ['pricing_templates', activeTenant?.id],
    queryFn: listPricingTemplates,
    enabled: open && !!activeTenant,
  })

  const { data: catalogItems = [] } = useQuery({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: getCatalogItems,
    enabled: open && !!activeTenant,
  })

  const { data: items = [], isLoading: itemsLoading } = useQuery({
    queryKey: ['pricing_template_items', templateId],
    queryFn: () => listPricingTemplateItems(templateId),
    enabled: open && !!templateId,
  })

  const catalogById = useMemo(() => {
    const map = new Map<string, (typeof catalogItems)[number]>()
    for (const ci of catalogItems) {
      if (ci.id) map.set(ci.id, ci)
    }
    return map
  }, [catalogItems])

  useEffect(() => {
    if (!open) return
    if (initialTemplateId) setTemplateId(initialTemplateId)
    else if (templates.length && !templateId) {
      const def = templates.find((x: PricingTemplate) => x.is_default) ?? templates[0]
      setTemplateId(def.id)
    }
  }, [open, templates, initialTemplateId, templateId])

  useEffect(() => {
    if (!items.length) return
    const next: Record<string, number> = {}
    for (const item of items) {
      next[item.id] = Number(item.default_quantity ?? 1)
    }
    setQuantities(next)
    if (!canEditPricing) {
      setDiscountPct(0)
      return
    }
    const firstDisc = items.find((i) => (i.default_discount_pct ?? 0) > 0)
    setDiscountPct(Number(firstDisc?.default_discount_pct ?? 0))
  }, [items, canEditPricing])

  if (!open) return null

  async function handleApply() {
    if (!templateId) return
    setSubmitting(true)
    try {
      await applyPricingTemplate({
        projectId,
        templateId,
        quantities,
        // Without commercial.pricing.edit the RPC rejects any non-zero override.
        // null keeps template default_discount_pct (allowed); 0 is an explicit office override.
        discountPct: canEditPricing ? discountPct : null,
      })
      await queryClient.invalidateQueries({ queryKey: ['project_lines', projectId] })
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', projectId] })
      await queryClient.invalidateQueries({ queryKey: ['project_lines_count', projectId] })
      toast({
        title: t('projects.lines.template_applied', 'Servei habitual aplicat'),
      })
      onApplied()
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.lines.template_apply_failed', "No s'ha pogut aplicar el servei"),
        description: isCommercialPricingPermissionDenied(err)
          ? t(
              'projects.lines.template_apply_pricing_denied',
              'Només l’oficina pot aplicar un descompte. Deixa’l a 0 % o demana permís comercial.',
            )
          : rpcErrorMessage(err) || undefined,
      })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[90vh] overflow-y-auto">
        <h3 className="text-lg font-semibold text-foreground mb-1">
          {t('projects.lines.apply_template_title', 'Aplicar servei habitual')}
        </h3>
        <p className="text-sm text-muted-foreground mb-4">
          {t(
            'projects.lines.apply_template_help',
            'Omple les quantitats demanades (km, hores…). Els preus surten del catàleg.',
          )}
        </p>

        <label className="text-sm font-medium block mb-1.5">
          {t('projects.lines.template_label', 'Servei habitual')}
        </label>
        <select
          value={templateId}
          onChange={(e) => setTemplateId(e.target.value)}
          className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm mb-4"
        >
          <option value="">{t('projects.lines.template_placeholder', 'Selecciona…')}</option>
          {templates.map((tpl) => (
            <option key={tpl.id} value={tpl.id}>
              {tpl.name}
            </option>
          ))}
        </select>

        {itemsLoading ? (
          <div className="py-6 flex justify-center">
            <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-primary" />
          </div>
        ) : (
          <div className="space-y-4 mb-4">
            {items.map((item) => {
              const cat = catalogById.get(item.catalog_item_id)
              const unit = cat?.unit ?? item.catalog_item_unit ?? ''
              const chips = item.prompt_quantity ? quantityChipsForUnit(unit) : []
              const label =
                item.prompt_label ||
                cat?.name ||
                item.catalog_item_name ||
                t('projects.lines.form.name_label', 'Descripció')
              return (
                <div key={item.id} className="rounded-lg border border-border p-3 space-y-2">
                  <div className="flex justify-between gap-2">
                    <span className="text-sm font-medium text-foreground">{label}</span>
                    {cat?.unit_price != null && (
                      <span className="text-xs text-muted-foreground tabular-nums">
                        {cat.unit_price} €/{unit || 'u'}
                      </span>
                    )}
                  </div>
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    value={quantities[item.id] ?? item.default_quantity}
                    onChange={(e) =>
                      setQuantities((prev) => ({
                        ...prev,
                        [item.id]: Number(e.target.value),
                      }))
                    }
                  />
                  {chips.length > 0 && (
                    <div className="flex flex-wrap gap-1">
                      {chips.map((q) => (
                        <button
                          key={q}
                          type="button"
                          onClick={() =>
                            setQuantities((prev) => ({ ...prev, [item.id]: q }))
                          }
                          className={`rounded-md border px-2 py-0.5 text-xs tabular-nums ${
                            quantities[item.id] === q
                              ? 'border-primary bg-primary/10 text-primary'
                              : 'border-border text-muted-foreground'
                          }`}
                        >
                          {formatQuantityChip(q)}
                          {unit ? ` ${unit}` : ''}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}

        <label className="text-sm font-medium block mb-1.5">
          {t('projects.lines.form.discount_label', 'Descompte (%)')}
        </label>
        <Input
          type="number"
          min="0"
          max="100"
          step="1"
          value={discountPct}
          disabled={!canEditPricing}
          onChange={(e) => setDiscountPct(Number(e.target.value))}
          className="mb-1"
        />
        {canEditPricing ? (
          <div className="mb-4 mt-1.5 flex flex-wrap gap-1">
            {DISCOUNT_CHIPS.map((d) => (
              <button
                key={d}
                type="button"
                onClick={() => setDiscountPct(d)}
                className={`rounded-md border px-2 py-0.5 text-xs tabular-nums ${
                  discountPct === d
                    ? 'border-primary bg-primary/10 text-primary'
                    : 'border-border text-muted-foreground'
                }`}
              >
                {d}%
              </button>
            ))}
          </div>
        ) : (
          <p className="mb-4 mt-1 text-xs text-muted-foreground">
            {t(
              'projects.lines.form.pricing_locked',
              'Només l’oficina pot canviar preus, descompte i IVA.',
            )}
          </p>
        )}

        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
            {t('projects.lines.form.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={handleApply} disabled={submitting || !templateId}>
            {t('projects.lines.apply_template', 'Aplicar')}
          </Button>
        </div>
      </div>
    </div>
  )
}

import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Trash2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { getCatalogItems } from '../api/catalogService'
import { listPublishedTemplatesForTenant } from '@/features/field-service/api/checklistTemplatesService'
import {
  createPricingTemplate,
  listPricingTemplateChecklists,
  listPricingTemplateItems,
  savePricingTemplateChecklists,
  savePricingTemplateItems,
  updatePricingTemplate,
  type PricingTemplate,
  type PricingTemplateItemInput,
} from '@/features/commercial/api/commercialFlowService'

type DraftItem = {
  key: string
  catalog_item_id: string
  default_quantity: number
  prompt_quantity: boolean
  prompt_label: string
  default_discount_pct: number
}

interface PricingTemplateFormProps {
  open: boolean
  onClose: () => void
  onSaved: () => void
  template?: PricingTemplate | null
}

function newDraftItem(): DraftItem {
  return {
    key: crypto.randomUUID(),
    catalog_item_id: '',
    default_quantity: 1,
    prompt_quantity: false,
    prompt_label: '',
    default_discount_pct: 0,
  }
}

export function PricingTemplateForm({
  open,
  onClose,
  onSaved,
  template,
}: PricingTemplateFormProps) {
  const { t } = useTranslation('catalog')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [category, setCategory] = useState('')
  const [isDefault, setIsDefault] = useState(false)
  const [items, setItems] = useState<DraftItem[]>([newDraftItem()])
  const [checklistIds, setChecklistIds] = useState<string[]>([])
  const [submitting, setSubmitting] = useState(false)
  const [loadingItems, setLoadingItems] = useState(false)

  const { data: catalogItems = [] } = useQuery({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: getCatalogItems,
    enabled: open && !!activeTenant,
  })

  const { data: checklistTemplates = [] } = useQuery({
    queryKey: ['checklist_templates_published', activeTenant?.id],
    queryFn: () => listPublishedTemplatesForTenant(activeTenant!.id!),
    enabled: open && !!activeTenant?.id,
  })

  const catalogOptions = useMemo(
    () =>
      [...catalogItems].sort((a, b) =>
        String(a.name ?? '').localeCompare(String(b.name ?? ''), 'ca'),
      ),
    [catalogItems],
  )

  useEffect(() => {
    if (!open) return
    let cancelled = false
    void (async () => {
      if (!template) {
        setName('')
        setDescription('')
        setCategory('')
        setIsDefault(false)
        setItems([newDraftItem()])
        setChecklistIds([])
        return
      }
      setName(template.name)
      setDescription(template.description ?? '')
      setCategory(template.category ?? '')
      setIsDefault(template.is_default)
      setLoadingItems(true)
      try {
        const [rows, linked] = await Promise.all([
          listPricingTemplateItems(template.id),
          listPricingTemplateChecklists(template.id),
        ])
        if (cancelled) return
        setItems(
          rows.length
            ? rows.map((row) => ({
                key: row.id,
                catalog_item_id: row.catalog_item_id,
                default_quantity: Number(row.default_quantity ?? 1),
                prompt_quantity: Boolean(row.prompt_quantity),
                prompt_label: row.prompt_label ?? '',
                default_discount_pct: Number(row.default_discount_pct ?? 0),
              }))
            : [newDraftItem()],
        )
        setChecklistIds(linked.map((row) => row.checklist_template_id))
      } catch (err) {
        if (!cancelled) {
          toast({
            variant: 'destructive',
            title: t('catalog.packs.load_items_failed', "No s'han pogut carregar les línies"),
            description: err instanceof Error ? err.message : undefined,
          })
        }
      } finally {
        if (!cancelled) setLoadingItems(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [open, template, t, toast])

  function updateItem(key: string, patch: Partial<DraftItem>) {
    setItems((prev) => prev.map((item) => (item.key === key ? { ...item, ...patch } : item)))
  }

  function toggleChecklist(id: string) {
    setChecklistIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id],
    )
  }

  async function handleSave() {
    const trimmedName = name.trim()
    if (!trimmedName) {
      toast({
        variant: 'destructive',
        title: t('catalog.errors.name_required', 'El nom és obligatori'),
      })
      return
    }
    const prepared: PricingTemplateItemInput[] = []
    for (const [index, item] of items.entries()) {
      if (!item.catalog_item_id) continue
      prepared.push({
        catalog_item_id: item.catalog_item_id,
        default_quantity: Number(item.default_quantity) || 0,
        prompt_quantity: item.prompt_quantity,
        prompt_label: item.prompt_label.trim() || null,
        default_discount_pct: Number(item.default_discount_pct) || 0,
        position: index,
      })
    }
    if (prepared.length === 0) {
      toast({
        variant: 'destructive',
        title: t('catalog.packs.items_required', 'Afegeix almenys una línia del catàleg'),
      })
      return
    }

    setSubmitting(true)
    try {
      let templateId = template?.id
      if (templateId) {
        await updatePricingTemplate({
          id: templateId,
          name: trimmedName,
          description: description.trim() || null,
          category: category.trim() || null,
          isDefault,
          isActive: true,
        })
      } else {
        templateId = await createPricingTemplate({
          name: trimmedName,
          description: description.trim() || null,
          category: category.trim() || null,
          isDefault,
        })
      }
      await savePricingTemplateItems(templateId, prepared)
      await savePricingTemplateChecklists(templateId, checklistIds)
      toast({ title: t('catalog.packs.saved', 'Servei habitual desat') })
      onSaved()
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('catalog.packs.save_failed', "No s'ha pogut desar el servei habitual"),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="sm:max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {template
              ? t('catalog.packs.form_edit', 'Editar servei habitual')
              : t('catalog.packs.form_create', 'Nou servei habitual')}
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-4 pt-2">
          <p className="text-sm text-muted-foreground">
            {t(
              'catalog.packs.form_help',
              'Un pack de línies del catàleg (p. ex. Visita estàndard) per aplicar-lo ràpidament a una OS. Pots vincular-hi checklists de visita.',
            )}
          </p>

          <div>
            <label className="text-sm font-medium block mb-1.5">
              {t('catalog.form.name_label', 'Nom')}
              <span className="text-destructive ml-1">*</span>
            </label>
            <Input value={name} onChange={(e) => setName(e.target.value)} />
          </div>

          <div>
            <label className="text-sm font-medium block mb-1.5">
              {t('catalog.form.description_label', 'Descripció')}
            </label>
            <Input value={description} onChange={(e) => setDescription(e.target.value)} />
          </div>

          <div>
            <label className="text-sm font-medium block mb-1.5">
              {t('catalog.form.category_label', 'Categoria')}
            </label>
            <Input value={category} onChange={(e) => setCategory(e.target.value)} />
          </div>

          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={isDefault}
              onChange={(e) => setIsDefault(e.target.checked)}
              className="rounded border-border"
            />
            {t('catalog.packs.is_default', 'Servei per defecte a les OS noves')}
          </label>

          <div className="space-y-2">
            <h4 className="text-sm font-semibold text-foreground">
              {t('catalog.packs.checklists_title', 'Checklists de visita')}
            </h4>
            <p className="text-xs text-muted-foreground">
              {t(
                'catalog.packs.checklists_help',
                'En aplicar aquest servei a una OS, també s’hi afegeixen aquestes checklists.',
              )}
            </p>
            {checklistTemplates.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t(
                  'catalog.packs.checklists_empty',
                  'No hi ha checklists publicades al tenant.',
                )}
              </p>
            ) : (
              <ul className="space-y-1.5 rounded-lg border border-border p-2 max-h-40 overflow-y-auto">
                {checklistTemplates.map((tpl) => (
                  <li key={tpl.id}>
                    <label className="flex items-center gap-2 text-sm px-1 py-1 rounded hover:bg-muted/50 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={checklistIds.includes(tpl.id)}
                        onChange={() => toggleChecklist(tpl.id)}
                        className="rounded border-border"
                      />
                      <span className="min-w-0 truncate">{tpl.name}</span>
                      {tpl.is_default && (
                        <span className="text-[10px] uppercase tracking-wide text-muted-foreground">
                          {t('catalog.packs.checklist_default', 'Defecte')}
                        </span>
                      )}
                    </label>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between gap-2">
              <h4 className="text-sm font-semibold text-foreground">
                {t('catalog.packs.items_title', 'Línies del pack')}
              </h4>
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => setItems((prev) => [...prev, newDraftItem()])}
              >
                <Plus className="h-4 w-4 mr-1" />
                {t('catalog.packs.add_item', 'Afegir línia')}
              </Button>
            </div>

            {loadingItems ? (
              <div className="flex justify-center py-8">
                <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-primary" />
              </div>
            ) : (
              <ul className="space-y-3">
                {items.map((item) => (
                  <li
                    key={item.key}
                    className="rounded-lg border border-border p-3 space-y-2"
                  >
                    <div className="flex gap-2 items-start">
                      <select
                        value={item.catalog_item_id}
                        onChange={(e) =>
                          updateItem(item.key, { catalog_item_id: e.target.value })
                        }
                        className="flex-1 rounded-md border border-border bg-background px-3 py-2 text-sm"
                      >
                        <option value="">
                          {t('catalog.packs.pick_catalog', 'Selecciona del catàleg…')}
                        </option>
                        {catalogOptions.map((ci) => (
                          <option key={ci.id!} value={ci.id!}>
                            {ci.name}
                            {ci.unit ? ` (${ci.unit})` : ''}
                            {ci.unit_price != null ? ` · ${ci.unit_price} €` : ''}
                          </option>
                        ))}
                      </select>
                      <button
                        type="button"
                        className="p-2 rounded-lg text-muted-foreground hover:text-destructive hover:bg-destructive/10"
                        title={t('catalog.packs.remove_item', 'Treure línia')}
                        onClick={() =>
                          setItems((prev) =>
                            prev.length <= 1
                              ? [newDraftItem()]
                              : prev.filter((row) => row.key !== item.key),
                          )
                        }
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                    <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                      <div>
                        <label className="text-xs text-muted-foreground">
                          {t('catalog.packs.qty', 'Quantitat')}
                        </label>
                        <Input
                          type="number"
                          min={0}
                          step="any"
                          value={item.default_quantity}
                          onChange={(e) =>
                            updateItem(item.key, {
                              default_quantity: Number(e.target.value) || 0,
                            })
                          }
                        />
                      </div>
                      <div>
                        <label className="text-xs text-muted-foreground">
                          {t('catalog.packs.discount', 'Descompte %')}
                        </label>
                        <Input
                          type="number"
                          min={0}
                          max={100}
                          step="any"
                          value={item.default_discount_pct}
                          onChange={(e) =>
                            updateItem(item.key, {
                              default_discount_pct: Number(e.target.value) || 0,
                            })
                          }
                        />
                      </div>
                      <div className="col-span-2 sm:col-span-1 flex items-end">
                        <label className="flex items-center gap-2 text-xs pb-2">
                          <input
                            type="checkbox"
                            checked={item.prompt_quantity}
                            onChange={(e) =>
                              updateItem(item.key, { prompt_quantity: e.target.checked })
                            }
                            className="rounded border-border"
                          />
                          {t('catalog.packs.prompt_qty', 'Demanar quantitat')}
                        </label>
                      </div>
                    </div>
                    {item.prompt_quantity && (
                      <Input
                        placeholder={t(
                          'catalog.packs.prompt_label',
                          'Etiqueta del prompt (p. ex. Km)',
                        )}
                        value={item.prompt_label}
                        onChange={(e) =>
                          updateItem(item.key, { prompt_label: e.target.value })
                        }
                      />
                    )}
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
              {t('catalog.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" onClick={() => void handleSave()} disabled={submitting}>
              {submitting
                ? t('catalog.packs.saving', 'Desant…')
                : t('catalog.packs.save', 'Desar')}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}

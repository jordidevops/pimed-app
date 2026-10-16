import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { searchContacts } from '@/features/contacts/api/contactsService'
import { getCatalogItems } from '@/features/catalog/api/catalogService'
import {
  cancelOrphanQuoteDraft,
  createOrphanQuoteDraft,
  issueOrphanCommercialDocument,
  listPricingTemplateItems,
  upsertCommercialDocumentLine,
} from '../api/commercialFlowService'
import {
  applyCalculatorRun,
  getCalculatorVersion,
  listActiveCalculators,
  previewCalculator,
} from '../api/calculatorService'
import type { CommercialQuickFlowRow } from '../api/commercialQuickFlowsService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { formatCalcErrorList } from '../utils/calculatorErrorLabels'
import {
  buildSyntheticQuotePreviewDoc,
  outputLinesToSyntheticInputs,
  type SyntheticPreviewLineInput,
} from '../utils/buildSyntheticQuotePreviewDoc'
import { LiveCommercialPreview } from './LiveCommercialPreview'
import {
  needsQtyPricePrompt,
  resolveLocale,
  type Definition,
  type LineOverrides,
  type ParamValues,
} from '@pimed/price-calculator'

type Step = 'client' | 'params' | 'preview'

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  flow: CommercialQuickFlowRow
  clientId?: string | null
  clientName?: string | null
  onBack?: () => void
}

function defaultParams(definition: Definition): ParamValues {
  const out: ParamValues = {}
  for (const p of definition.parameters ?? []) {
    if (p.default !== undefined && p.default !== null) out[p.key] = p.default
    else if (p.type === 'boolean') out[p.key] = false
    else out[p.key] = p.min ?? 0
  }
  return out
}

function needsParamStep(definition: Definition): boolean {
  const needsParams = (definition.parameters ?? []).some(
    (p) => p.required && (p.default === undefined || p.default === null),
  )
  const needsQtyPrice = (definition.lines ?? []).some((l) => needsQtyPricePrompt(l))
  return needsParams || needsQtyPrice
}

export function LaunchCommercialFlowDialog({
  open,
  onOpenChange,
  flow,
  clientId: initialClientId = null,
  clientName: initialClientName = null,
  onBack,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const navigate = useNavigate()
  const { activeTenant } = useTenant()
  const canEditPricing = usePermission('commercial.pricing.edit')

  const isCalc = !!flow.calculator_definition_id
  const [step, setStep] = useState<Step>('client')
  const [clientId, setClientId] = useState(initialClientId ?? '')
  const [clientSearch, setClientSearch] = useState(initialClientName ?? '')
  const [params, setParams] = useState<ParamValues>({})
  const [lineOverrides, setLineOverrides] = useState<LineOverrides>({})
  const [habitQty, setHabitQty] = useState<Record<string, number>>({})
  const [busy, setBusy] = useState(false)

  const { data: contacts = [] } = useQuery({
    queryKey: ['contacts_flow_launch', activeTenant?.id, clientSearch],
    queryFn: () => searchContacts({ q: clientSearch.trim() || undefined, limit: 20 }),
    enabled: open && !!activeTenant,
  })
  const selectedContact = contacts.find((c) => c.id === clientId) ?? null

  const { data: calculators = [] } = useQuery({
    queryKey: ['calculator_definitions_active', activeTenant?.id],
    queryFn: listActiveCalculators,
    enabled: open && !!activeTenant && isCalc,
  })
  const selectedCalc =
    calculators.find((c) => c.id === flow.calculator_definition_id) ?? null

  const versionQ = useQuery({
    queryKey: ['calculator_version', selectedCalc?.published_version_id],
    queryFn: () => getCalculatorVersion(selectedCalc!.published_version_id!),
    enabled: open && !!selectedCalc?.published_version_id,
  })
  const definition =
    versionQ.data?.definition ??
    (selectedCalc?.published_version_id ? selectedCalc.draft_definition : null)

  const { data: habitItems = [] } = useQuery({
    queryKey: ['pricing_template_items', flow.pricing_template_id],
    queryFn: () => listPricingTemplateItems(flow.pricing_template_id!),
    enabled: open && !isCalc && !!flow.pricing_template_id,
  })

  const { data: catalogItems = [] } = useQuery({
    queryKey: ['catalog_items', activeTenant?.id],
    queryFn: getCatalogItems,
    enabled: open && !isCalc && !!activeTenant,
  })
  const catalogById = useMemo(() => {
    const m = new Map(catalogItems.map((c) => [c.id!, c]))
    return m
  }, [catalogItems])

  useEffect(() => {
    if (!open) {
      setStep('client')
      setClientId(initialClientId ?? '')
      setClientSearch(initialClientName ?? '')
      setParams({})
      setLineOverrides({})
      setHabitQty({})
      setBusy(false)
      return
    }
    setClientId(initialClientId ?? '')
    setClientSearch(initialClientName ?? '')
    if (initialClientId) {
      if (isCalc) setStep('params')
      else setStep('params')
    } else {
      setStep('client')
    }
  }, [open, initialClientId, initialClientName, isCalc, flow.id])

  useEffect(() => {
    if (!open || !definition || !isCalc) return
    setParams(defaultParams(definition))
    setLineOverrides({})
    if (clientId && !needsParamStep(definition)) setStep('preview')
  }, [open, definition, isCalc, clientId])

  useEffect(() => {
    if (!open || isCalc || !habitItems.length) return
    const next: Record<string, number> = {}
    for (const item of habitItems) {
      next[item.id] = Number(item.default_quantity ?? 1)
    }
    setHabitQty(next)
  }, [open, isCalc, habitItems])

  const calcPreview = useMemo(() => {
    if (!definition || !isCalc) return null
    return previewCalculator(definition, params, 'ca', lineOverrides)
  }, [definition, params, lineOverrides, isCalc])

  const habitLines: SyntheticPreviewLineInput[] = useMemo(() => {
    if (isCalc) return []
    return habitItems.map((item) => {
      const catalog = catalogById.get(item.catalog_item_id)
      return {
        kind: catalog?.kind === 'product' ? 'product' : 'service',
        name: catalog?.name ?? item.catalog_item_name ?? '',
        unit: catalog?.unit ?? item.catalog_item_unit ?? 'u',
        quantity: Number(habitQty[item.id] ?? item.default_quantity ?? 1),
        unit_price: Number(catalog?.unit_price ?? item.catalog_item_unit_price ?? 0),
        discount_pct: Number(item.default_discount_pct ?? 0),
        tax_rate: Number(catalog?.tax_rate ?? 21),
      }
    })
  }, [catalogById, habitItems, habitQty, isCalc])

  const previewDoc = useMemo(() => {
    if (!activeTenant?.id || !clientId) return null
    if (isCalc) {
      if (!calcPreview || calcPreview.errors.length) return null
      return buildSyntheticQuotePreviewDoc({
        tenantId: activeTenant.id,
        clientId,
        title: flow.name,
        buyer: {
          display_name: selectedContact?.display_name ?? (clientSearch || null),
          email: selectedContact?.email ?? null,
          phone: selectedContact?.phone ?? null,
        },
        formalizationMode: flow.formalization_mode,
        templateId: flow.quote_template_id,
        lines: outputLinesToSyntheticInputs(calcPreview.lines),
      })
    }
    if (!habitLines.length) return null
    return buildSyntheticQuotePreviewDoc({
      tenantId: activeTenant.id,
      clientId,
      title: flow.name,
      buyer: {
        display_name: selectedContact?.display_name ?? (clientSearch || null),
        email: selectedContact?.email ?? null,
        phone: selectedContact?.phone ?? null,
      },
      formalizationMode: flow.formalization_mode,
      templateId: flow.quote_template_id,
      lines: habitLines,
    })
  }, [
    activeTenant?.id,
    calcPreview,
    clientId,
    clientSearch,
    flow,
    habitLines,
    isCalc,
    selectedContact,
  ])

  const promptLines = useMemo(
    () => (definition?.lines ?? []).filter((l) => needsQtyPricePrompt(l)),
    [definition],
  )

  function afterClient() {
    if (isCalc) {
      if (definition && needsParamStep(definition)) setStep('params')
      else setStep('preview')
      return
    }
    setStep('params')
  }

  async function issue() {
    if (!activeTenant?.id || !clientId || !previewDoc) return
    if (isCalc && (!selectedCalc?.published_version_id || !definition || calcPreview?.errors.length)) {
      return
    }
    setBusy(true)
    let documentId: string | null = null
    try {
      documentId = await createOrphanQuoteDraft({
        tenantId: activeTenant.id,
        clientId,
        formalizationMode: flow.formalization_mode,
      })
      if (isCalc && selectedCalc?.published_version_id && definition) {
        await applyCalculatorRun({
          versionId: selectedCalc.published_version_id,
          params,
          documentId,
          clientOpId: crypto.randomUUID(),
          definition,
          lineOverrides,
        })
      } else {
        for (const [index, line] of habitLines.entries()) {
          const item = habitItems[index]
          await upsertCommercialDocumentLine({
            documentId,
            catalogItemId: item?.catalog_item_id ?? null,
            kind: line.kind,
            name: line.name,
            unit: line.unit,
            quantity: line.quantity,
            unitPrice: line.unit_price,
            discountPct: line.discount_pct ?? 0,
            taxRate: line.tax_rate ?? 21,
            position: index,
          })
        }
      }
      await issueOrphanCommercialDocument({
        documentId,
        formalizationMode: flow.formalization_mode,
        fullBodyTemplateId: flow.quote_template_id,
      })
      toast({ title: t('projects.orphan.issued', 'Pressupost emès') })
      onOpenChange(false)
      navigate(`/sales/quotes/${documentId}`)
    } catch (err) {
      if (documentId) {
        try {
          await cancelOrphanQuoteDraft(documentId, 'flow_issue_failed')
        } catch {
          /* best-effort */
        }
      }
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    } finally {
      setBusy(false)
    }
  }

  if (!canEditPricing) {
    return (
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{flow.name}</DialogTitle>
            <DialogDescription>
              {t(
                'projects.quotes.quick_no_pricing',
                'Cal el permís d’editar preus per usar el flux ràpid amb calculadora.',
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              {t('common:close', 'Tancar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    )
  }

  const wide = step === 'preview'

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && onOpenChange(next)}>
      <DialogContent className={wide ? 'sm:max-w-3xl' : 'sm:max-w-lg'}>
        <DialogHeader>
          <DialogTitle>{flow.name}</DialogTitle>
          <DialogDescription>
            {flow.formalization_mode === 'separate_agreement'
              ? t(
                  'projects.flows.separate_note',
                  'El contracte es prepara després d’acceptar el pressupost.',
                )
              : t(
                  'projects.flows.launch_help',
                  'Plantilla i formalització ja definides al flux.',
                )}
          </DialogDescription>
        </DialogHeader>

        {step === 'client' ? (
          <div className="space-y-3">
            <Input
              value={clientSearch}
              onChange={(e) => setClientSearch(e.target.value)}
              placeholder={t('projects.quotes.quick_client_search', 'Cerca client…')}
            />
            <ul className="max-h-56 space-y-1 overflow-y-auto rounded-md border border-border p-1">
              {contacts.map((c) => (
                <li key={c.id}>
                  <button
                    type="button"
                    className={`w-full rounded-md px-3 py-2 text-left text-sm hover:bg-muted ${
                      clientId === c.id ? 'bg-primary/10' : ''
                    }`}
                    onClick={() => {
                      setClientId(c.id)
                      setClientSearch(c.display_name ?? c.id)
                    }}
                  >
                    {c.display_name}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        ) : null}

        {step === 'params' && isCalc && definition ? (
          <div className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              {definition.parameters.map((p) => (
                <div key={p.key} className="space-y-1">
                  <Label>{resolveLocale(p.label, 'ca') || p.key}</Label>
                  <Input
                    type={p.type === 'boolean' ? 'text' : 'number'}
                    value={params[p.key] == null ? '' : String(params[p.key])}
                    onChange={(e) => {
                      if (p.type === 'boolean') {
                        setParams((prev) => ({
                          ...prev,
                          [p.key]: e.target.value === 'true',
                        }))
                        return
                      }
                      const n = Number(e.target.value.replace(',', '.'))
                      setParams((prev) => ({
                        ...prev,
                        [p.key]: Number.isFinite(n) ? n : 0,
                      }))
                    }}
                  />
                </div>
              ))}
            </div>
            {promptLines.map((line) => {
              const fromRun = calcPreview?.lines.find((l) => l.key === line.key)
              const ov = lineOverrides[line.key]
              return (
                <div key={line.key} className="grid grid-cols-2 gap-2">
                  <p className="col-span-2 text-xs font-medium">
                    {resolveLocale(line.name, 'ca') || line.key}
                  </p>
                  <Input
                    type="number"
                    placeholder={t('projects.lines.form.quantity_label', 'Quantitat')}
                    value={ov?.quantity ?? fromRun?.quantity ?? ''}
                    onChange={(e) =>
                      setLineOverrides((prev) => ({
                        ...prev,
                        [line.key]: { ...prev[line.key], quantity: e.target.value },
                      }))
                    }
                  />
                  <Input
                    type="number"
                    placeholder={t('projects.lines.form.unit_price_label', 'Preu unitari')}
                    value={ov?.unit_price ?? fromRun?.unit_price ?? ''}
                    onChange={(e) =>
                      setLineOverrides((prev) => ({
                        ...prev,
                        [line.key]: { ...prev[line.key], unit_price: e.target.value },
                      }))
                    }
                  />
                </div>
              )
            })}
            {calcPreview?.errors.length ? (
              <p className="text-sm text-destructive">
                {formatCalcErrorList(definition, calcPreview.errors, 'ca')}
              </p>
            ) : null}
          </div>
        ) : null}

        {step === 'params' && !isCalc ? (
          <div className="space-y-3">
            {habitItems.map((item) => {
              const cat = catalogById.get(item.catalog_item_id)
              return (
                <div key={item.id} className="space-y-1">
                  <Label>
                    {cat?.name ?? item.catalog_item_name ?? item.id}
                    {cat?.unit ? ` (${cat.unit})` : ''}
                  </Label>
                  <Input
                    type="number"
                    step="0.001"
                    value={habitQty[item.id] ?? item.default_quantity ?? 1}
                    onChange={(e) => {
                      const n = Number(e.target.value.replace(',', '.'))
                      setHabitQty((prev) => ({
                        ...prev,
                        [item.id]: Number.isFinite(n) ? n : 0,
                      }))
                    }}
                  />
                </div>
              )
            })}
          </div>
        ) : null}

        {step === 'preview' ? (
          <div className="max-h-[75vh] space-y-3 overflow-y-auto">
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.flows.preview_locked',
                'Plantilla i formalització fixades pel flux (sense canviar aquí).',
              )}
            </p>
            {previewDoc ? (
              <LiveCommercialPreview doc={previewDoc} templateId={flow.quote_template_id} />
            ) : (
              <p className="text-sm text-muted-foreground">
                {t(
                  'projects.quotes.quick_preview_unavailable',
                  'No es pot mostrar la vista prèvia fins que la calculadora tingui línies vàlides.',
                )}
              </p>
            )}
          </div>
        ) : null}

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => {
              if (step === 'client') {
                if (onBack) onBack()
                else onOpenChange(false)
                return
              }
              if (step === 'params') {
                if (initialClientId) {
                  if (onBack) onBack()
                  else onOpenChange(false)
                } else setStep('client')
                return
              }
              if (isCalc && definition && needsParamStep(definition)) setStep('params')
              else if (!isCalc) setStep('params')
              else if (initialClientId) {
                if (onBack) onBack()
                else onOpenChange(false)
              } else setStep('client')
            }}
          >
            {t('projects.quotes.wizard_back', 'Enrere')}
          </Button>
          {step === 'client' ? (
            <Button type="button" disabled={!clientId} onClick={afterClient}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : null}
          {step === 'params' ? (
            <Button
              type="button"
              disabled={isCalc ? !!calcPreview?.errors.length : habitLines.length === 0}
              onClick={() => setStep('preview')}
            >
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : null}
          {step === 'preview' ? (
            <Button
              type="button"
              disabled={busy || !previewDoc}
              onClick={() => void issue()}
            >
              {t('projects.orphan.issue', 'Emetre pressupost')}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

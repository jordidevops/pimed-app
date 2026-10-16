import { useEffect, useMemo, useRef, useState } from 'react'
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
import { useEffectiveSettings } from '@/hooks/useSettings'
import { usePermission } from '@/hooks/usePermission'
import { searchContacts } from '@/features/contacts/api/contactsService'
import {
  cancelOrphanQuoteDraft,
  createOrphanQuoteDraft,
  issueOrphanCommercialDocument,
} from '../api/commercialFlowService'
import {
  applyCalculatorRun,
  getCalculatorVersion,
  listActiveCalculators,
  previewCalculator,
} from '../api/calculatorService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { formatCalcErrorList } from '../utils/calculatorErrorLabels'
import {
  buildSyntheticQuotePreviewDoc,
  outputLinesToSyntheticInputs,
} from '../utils/buildSyntheticQuotePreviewDoc'
import {
  COMMERCIAL_QUOTE_TEMPLATE_ID_KEY,
  parseCommercialSettingId,
  readExplicitFormalizationModeDefault,
  shouldSkipCommercialTemplateStep,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import { FormalizationChoiceCards } from './QuoteDraftStepBar'
import { DocumentTemplateSelect } from './AgreementTemplateSelect'
import { LiveCommercialPreview } from './LiveCommercialPreview'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import {
  needsQtyPricePrompt,
  resolveLocale,
  type Definition,
  type LineOverrides,
  type ParamValues,
} from '@pimed/price-calculator'

type Step = 'client' | 'source' | 'params' | 'preview'

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  clientId?: string | null
  clientName?: string | null
  formalizationMode: FormalizationMode
  onBack: () => void
  onChangeFormalization?: () => void
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

export function CreateQuickQuoteDialog({
  open,
  onOpenChange,
  clientId: initialClientId = null,
  clientName: initialClientName = null,
  formalizationMode,
  onBack,
  onChangeFormalization,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const navigate = useNavigate()
  const { activeTenant } = useTenant()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const { data: effective } = useEffectiveSettings({
    tenantId: activeTenant?.id ?? null,
  })
  const skipTemplate = shouldSkipCommercialTemplateStep(effective, COMMERCIAL_QUOTE_TEMPLATE_ID_KEY)
  const defaultTemplateId =
    parseCommercialSettingId(effective, COMMERCIAL_QUOTE_TEMPLATE_ID_KEY) ?? ''

  const [step, setStep] = useState<Step>('client')
  const [clientId, setClientId] = useState(initialClientId ?? '')
  const [clientSearch, setClientSearch] = useState(initialClientName ?? '')
  const [calcId, setCalcId] = useState('')
  const [params, setParams] = useState<ParamValues>({})
  const [lineOverrides, setLineOverrides] = useState<LineOverrides>({})
  const [mode, setMode] = useState<FormalizationMode>(formalizationMode)
  const [templateId, setTemplateId] = useState(defaultTemplateId)
  const [forceAskTemplate, setForceAskTemplate] = useState(false)
  const [busy, setBusy] = useState(false)
  const issueInFlight = useRef(false)

  const { data: contacts = [] } = useQuery({
    queryKey: ['contacts_quick_quote', activeTenant?.id, clientSearch],
    queryFn: () => searchContacts({ q: clientSearch.trim() || undefined, limit: 20 }),
    enabled: open && !!activeTenant,
  })

  const selectedContact = contacts.find((c) => c.id === clientId) ?? null

  const { data: calculators = [] } = useQuery({
    queryKey: ['calculator_definitions_active', activeTenant?.id],
    queryFn: listActiveCalculators,
    enabled: open && !!activeTenant && canEditPricing,
  })

  const selectedCalc = calculators.find((c) => c.id === calcId) ?? null
  const versionQ = useQuery({
    queryKey: ['calculator_version', selectedCalc?.published_version_id],
    queryFn: () => getCalculatorVersion(selectedCalc!.published_version_id!),
    enabled: open && !!selectedCalc?.published_version_id,
  })
  const definition =
    versionQ.data?.definition ??
    (selectedCalc?.published_version_id ? selectedCalc.draft_definition : null)

  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const quoteTemplates = useMemo(
    () =>
      templates
        .filter(
          (tpl) =>
            tpl.category === 'quote' &&
            (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
            !!tpl.id,
        )
        .map((tpl) => ({
          id: tpl.id!,
          name: tpl.name,
          is_platform_default: tpl.is_platform_default,
        })),
    [templates],
  )

  useEffect(() => {
    if (!open) {
      setStep('client')
      setClientId(initialClientId ?? '')
      setClientSearch(initialClientName ?? '')
      setCalcId('')
      setParams({})
      setLineOverrides({})
      setMode(formalizationMode)
      setTemplateId(defaultTemplateId)
      setForceAskTemplate(false)
      setBusy(false)
      issueInFlight.current = false
      return
    }
    setMode(formalizationMode)
    if (initialClientId) {
      setClientId(initialClientId)
      setStep('source')
    }
  }, [open, initialClientId, initialClientName, formalizationMode, defaultTemplateId])

  useEffect(() => {
    if (!definition) return
    setParams(defaultParams(definition))
    setLineOverrides({})
  }, [definition])

  const preview = useMemo(() => {
    if (!definition) return null
    return previewCalculator(definition, params, 'ca', lineOverrides)
  }, [definition, params, lineOverrides])

  const previewDoc = useMemo(() => {
    if (!activeTenant?.id || !clientId || !preview || preview.errors.length) return null
    return buildSyntheticQuotePreviewDoc({
      tenantId: activeTenant.id,
      clientId,
      title: selectedCalc?.name,
      buyer: {
        display_name: selectedContact?.display_name ?? (clientSearch || null),
        email: selectedContact?.email ?? null,
        phone: selectedContact?.phone ?? null,
      },
      formalizationMode: mode,
      templateId,
      lines: outputLinesToSyntheticInputs(preview.lines),
    })
  }, [
    activeTenant?.id,
    clientId,
    clientSearch,
    mode,
    preview,
    selectedCalc?.name,
    selectedContact,
    templateId,
  ])

  const promptLines = useMemo(
    () => (definition?.lines ?? []).filter((l) => needsQtyPricePrompt(l)),
    [definition],
  )

  function goAfterSource() {
    if (!definition) return
    if (needsParamStep(definition)) {
      setStep('params')
      return
    }
    setStep('preview')
  }

  async function issue() {
    if (
      !activeTenant?.id ||
      !clientId ||
      !selectedCalc?.published_version_id ||
      !definition ||
      issueInFlight.current
    ) {
      return
    }
    if (preview?.errors.length) {
      toast({
        variant: 'destructive',
        description: formatCalcErrorList(definition, preview.errors, 'ca'),
      })
      return
    }
    issueInFlight.current = true
    setBusy(true)
    let documentId: string | null = null
    try {
      documentId = await createOrphanQuoteDraft({
        tenantId: activeTenant.id,
        clientId,
        formalizationMode: mode,
      })
      await applyCalculatorRun({
        versionId: selectedCalc.published_version_id,
        params,
        documentId,
        clientOpId: crypto.randomUUID(),
        definition,
        lineOverrides,
      })
      await issueOrphanCommercialDocument({
        documentId,
        formalizationMode: mode,
        fullBodyTemplateId: templateId || null,
      })
      toast({ title: t('projects.orphan.issued', 'Pressupost emès') })
      onOpenChange(false)
      navigate(`/sales/quotes/${documentId}`)
    } catch (err) {
      if (documentId) {
        try {
          await cancelOrphanQuoteDraft(documentId, 'quick_issue_failed')
        } catch {
          /* best-effort */
        }
      }
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    } finally {
      issueInFlight.current = false
      setBusy(false)
    }
  }

  if (!canEditPricing) {
    return (
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('projects.quotes.wizard_type_quick_title', 'Ràpid')}</DialogTitle>
            <DialogDescription>
              {t(
                'projects.quotes.quick_no_pricing',
                'Cal el permís d’editar preus per usar el flux ràpid amb calculadora.',
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onBack}>
              {t('projects.quotes.wizard_back', 'Enrere')}
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
          <DialogTitle>
            {step === 'client'
              ? t('projects.quotes.quick_client_title', 'Client')
              : step === 'source'
                ? t('projects.quotes.quick_source_title', 'Font')
                : step === 'params'
                  ? t('projects.quotes.quick_params_title', 'Paràmetres')
                  : t('projects.quotes.quick_preview_title', 'Vista prèvia i emissió')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.quotes.quick_help',
              'Contacte → calculadora → vista prèvia → emetre. Sense obrir ordre de servei.',
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

        {step === 'source' ? (
          <div className="space-y-3">
            {calculators.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t(
                  'projects.lines.calculator_empty',
                  'No hi ha cap calculadora activa. Activa’n una a Catàleg → Calculadores.',
                )}
              </p>
            ) : (
              <div className="space-y-1">
                <Label htmlFor="quick-calc">
                  {t('projects.lines.calculator_pick', 'Calculadora')}
                </Label>
                <select
                  id="quick-calc"
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={calcId}
                  onChange={(e) => setCalcId(e.target.value)}
                >
                  <option value="">
                    {t('projects.lines.calculator_pick_ph', 'Tria…')}
                  </option>
                  {calculators.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
                {calcId && selectedCalc && !selectedCalc.published_version_id ? (
                  <p className="text-sm text-destructive" role="alert">
                    {t(
                      'projects.lines.calculator_not_published',
                      'Aquesta calculadora no té versió publicada. Torna a Catàleg, publica i activa.',
                    )}
                  </p>
                ) : null}
              </div>
            )}
          </div>
        ) : null}

        {step === 'params' && definition ? (
          <div className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              {definition.parameters.map((p) => (
                <div key={p.key} className="space-y-1">
                  <Label htmlFor={`quick-p-${p.key}`}>
                    {resolveLocale(p.label, 'ca') || p.key}
                  </Label>
                  {p.type === 'boolean' ? (
                    <select
                      id={`quick-p-${p.key}`}
                      className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                      value={String(Boolean(params[p.key]))}
                      onChange={(e) =>
                        setParams((prev) => ({
                          ...prev,
                          [p.key]: e.target.value === 'true',
                        }))
                      }
                    >
                      <option value="false">false</option>
                      <option value="true">true</option>
                    </select>
                  ) : (
                    <Input
                      id={`quick-p-${p.key}`}
                      type="number"
                      value={params[p.key] == null ? '' : String(params[p.key])}
                      onChange={(e) => {
                        const n = Number(e.target.value.replace(',', '.'))
                        setParams((prev) => ({
                          ...prev,
                          [p.key]: Number.isFinite(n) ? n : 0,
                        }))
                      }}
                    />
                  )}
                </div>
              ))}
            </div>
            {promptLines.length > 0 ? (
              <div className="space-y-2 rounded-lg border border-dashed border-border p-3">
                <p className="text-sm font-medium">
                  {t(
                    'projects.lines.calculator_prompt_qty_price',
                    'Quantitat i preu unitari',
                  )}
                </p>
                {promptLines.map((line) => {
                  const fromRun = preview?.lines.find((l) => l.key === line.key)
                  const ov = lineOverrides[line.key]
                  return (
                    <div key={line.key} className="grid grid-cols-2 gap-2">
                      <p className="col-span-2 text-xs font-medium">
                        {resolveLocale(line.name, 'ca') || line.key}
                      </p>
                      <div className="space-y-1">
                        <Label className="text-xs">
                          {t('projects.lines.form.quantity_label', 'Quantitat')}
                        </Label>
                        <Input
                          type="number"
                          step="0.001"
                          value={ov?.quantity ?? fromRun?.quantity ?? ''}
                          onChange={(e) =>
                            setLineOverrides((prev) => ({
                              ...prev,
                              [line.key]: {
                                ...prev[line.key],
                                quantity: e.target.value,
                              },
                            }))
                          }
                        />
                      </div>
                      <div className="space-y-1">
                        <Label className="text-xs">
                          {t('projects.lines.form.unit_price_label', 'Preu unitari')}
                        </Label>
                        <Input
                          type="number"
                          step="0.01"
                          value={ov?.unit_price ?? fromRun?.unit_price ?? ''}
                          onChange={(e) =>
                            setLineOverrides((prev) => ({
                              ...prev,
                              [line.key]: {
                                ...prev[line.key],
                                unit_price: e.target.value,
                              },
                            }))
                          }
                        />
                      </div>
                    </div>
                  )
                })}
              </div>
            ) : null}
            {preview?.errors.length ? (
              <p className="text-sm text-destructive">
                {formatCalcErrorList(definition, preview.errors, 'ca')}
              </p>
            ) : preview?.totals ? (
              <p className="text-sm font-medium">
                {t('projects.quotes.quick_total', 'Total: {{amount}} €', {
                  amount: preview.totals.total,
                })}
              </p>
            ) : null}
          </div>
        ) : null}

        {step === 'preview' ? (
          <div className="max-h-[75vh] space-y-3 overflow-y-auto">
            <FormalizationChoiceCards mode={mode} disabled={busy} onChange={setMode} />
            {onChangeFormalization && readExplicitFormalizationModeDefault(effective) ? (
              <Button type="button" variant="ghost" size="sm" onClick={onChangeFormalization}>
                {t('projects.quotes.wizard_change_default', 'Canviar')}
              </Button>
            ) : null}
            {skipTemplate && !forceAskTemplate ? (
              <div className="flex items-center justify-between gap-2 rounded-xl border border-border bg-muted/30 px-3 py-2">
                <p className="text-sm text-muted-foreground">
                  {t(
                    'projects.quotes.using_default_template',
                    'S’usarà la plantilla per defecte del tenant.',
                  )}
                </p>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => setForceAskTemplate(true)}
                >
                  {t('projects.quotes.wizard_change_default', 'Canviar')}
                </Button>
              </div>
            ) : (
              <DocumentTemplateSelect
                templates={quoteTemplates}
                value={templateId}
                onChange={setTemplateId}
                disabled={busy}
                emptyOptionLabel={t(
                  'projects.orphan.system_format',
                  'Format estàndard (sense plantilla pròpia)',
                )}
                previewFor={
                  previewDoc
                    ? (id) => <LiveCommercialPreview doc={previewDoc} templateId={id} />
                    : undefined
                }
              />
            )}
            {previewDoc ? (
              <LiveCommercialPreview doc={previewDoc} templateId={templateId} />
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
                onBack()
                return
              }
              if (step === 'source') {
                if (initialClientId) onBack()
                else setStep('client')
                return
              }
              if (step === 'params') {
                setStep('source')
                return
              }
              if (step === 'preview') {
                setStep(definition && needsParamStep(definition) ? 'params' : 'source')
              }
            }}
          >
            {t('projects.quotes.wizard_back', 'Enrere')}
          </Button>
          {step === 'client' ? (
            <Button type="button" disabled={!clientId} onClick={() => setStep('source')}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : null}
          {step === 'source' ? (
            <Button
              type="button"
              disabled={!calcId || !definition || !selectedCalc?.published_version_id}
              onClick={goAfterSource}
            >
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : null}
          {step === 'params' ? (
            <Button
              type="button"
              disabled={!!preview?.errors.length}
              onClick={() => setStep('preview')}
            >
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : null}
          {step === 'preview' ? (
            <Button
              type="button"
              disabled={busy || !!preview?.errors.length || !previewDoc}
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

import { useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { listActiveCalculators } from '../api/calculatorService'
import { listPricingTemplates } from '../api/commercialFlowService'
import {
  createCommercialQuickFlow,
  listCommercialQuickFlows,
  setCommercialQuickFlowStatus,
  updateCommercialQuickFlow,
  type CommercialQuickFlowRow,
  type CommercialQuickFlowStatus,
} from '../api/commercialQuickFlowsService'
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import { LaunchCommercialFlowDialog } from './LaunchCommercialFlowDialog'

type FormState = {
  name: string
  description: string
  sourceKind: 'calculator' | 'habit'
  calculatorDefinitionId: string
  pricingTemplateId: string
  quoteTemplateId: string
  formalizationMode: FormalizationMode
  agreementTemplateId: string
  status: CommercialQuickFlowStatus
}

const emptyForm = (): FormState => ({
  name: '',
  description: '',
  sourceKind: 'calculator',
  calculatorDefinitionId: '',
  pricingTemplateId: '',
  quoteTemplateId: '',
  formalizationMode: 'signed_quote',
  agreementTemplateId: '',
  status: 'draft',
})

export function CommercialFlowsPage() {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const canEdit = activeRole === 'owner' || activeRole === 'manager'
  const canLaunch = usePermission('commercial.pricing.edit')
  const queryClient = useQueryClient()

  const [editorOpen, setEditorOpen] = useState(false)
  const [editing, setEditing] = useState<CommercialQuickFlowRow | null>(null)
  const [form, setForm] = useState<FormState>(emptyForm)
  const [busy, setBusy] = useState(false)
  const [launchFlow, setLaunchFlow] = useState<CommercialQuickFlowRow | null>(null)

  const { data: flows = [], isLoading } = useQuery({
    queryKey: ['commercial_quick_flows', activeTenant?.id],
    queryFn: () => listCommercialQuickFlows({ status: 'all' }),
    enabled: !!activeTenant,
  })

  const { data: calculators = [] } = useQuery({
    queryKey: ['calculator_definitions_active', activeTenant?.id],
    queryFn: listActiveCalculators,
    enabled: !!activeTenant && canEdit,
  })

  const { data: habits = [] } = useQuery({
    queryKey: ['pricing_templates', activeTenant?.id],
    queryFn: listPricingTemplates,
    enabled: !!activeTenant && canEdit,
  })

  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const quoteTemplates = useMemo(
    () =>
      templates.filter(
        (tpl) =>
          !tpl.is_platform_default &&
          tpl.category === 'quote' &&
          !!tpl.id &&
          (tpl.template_type === 'html' || tpl.template_type === 'docx'),
      ),
    [templates],
  )
  const agreementTemplates = useMemo(
    () =>
      templates.filter(
        (tpl) =>
          tpl.category === 'commercial_agreement' &&
          !!tpl.id &&
          (tpl.is_platform_default || tpl.tenant_id === activeTenant?.id),
      ),
    [templates, activeTenant?.id],
  )

  const calcById = useMemo(() => {
    const m = new Map(calculators.map((c) => [c.id, c]))
    return m
  }, [calculators])
  const habitById = useMemo(() => {
    const m = new Map(habits.map((h) => [h.id, h]))
    return m
  }, [habits])

  function openCreate() {
    setEditing(null)
    setForm(emptyForm())
    setEditorOpen(true)
  }

  function openEdit(row: CommercialQuickFlowRow) {
    setEditing(row)
    setForm({
      name: row.name,
      description: row.description ?? '',
      sourceKind: row.calculator_definition_id ? 'calculator' : 'habit',
      calculatorDefinitionId: row.calculator_definition_id ?? '',
      pricingTemplateId: row.pricing_template_id ?? '',
      quoteTemplateId: row.quote_template_id,
      formalizationMode: row.formalization_mode,
      agreementTemplateId: row.agreement_template_id ?? '',
      status: row.status,
    })
    setEditorOpen(true)
  }

  async function save() {
    if (!canEdit || busy) return
    setBusy(true)
    try {
      const payload = {
        name: form.name,
        description: form.description || null,
        status: form.status,
        calculatorDefinitionId:
          form.sourceKind === 'calculator' ? form.calculatorDefinitionId || null : null,
        pricingTemplateId: form.sourceKind === 'habit' ? form.pricingTemplateId || null : null,
        quoteTemplateId: form.quoteTemplateId,
        formalizationMode: form.formalizationMode,
        agreementTemplateId:
          form.formalizationMode === 'separate_agreement'
            ? form.agreementTemplateId || null
            : null,
      }
      if (editing) await updateCommercialQuickFlow(editing.id, payload)
      else {
        if (!activeTenant?.id) throw new Error('No tenant actiu')
        await createCommercialQuickFlow(activeTenant.id, payload)
      }
      await queryClient.invalidateQueries({ queryKey: ['commercial_quick_flows'] })
      setEditorOpen(false)
      toast({ title: t('common:saved', 'Desat') })
    } catch (err) {
      const raw = err instanceof Error ? err.message : String(err)
      const msg =
        raw === 'flow_source_required'
          ? t(
              'projects.flows.error_source',
              'Un flux actiu necessita exactament una font: calculadora o servei habitual.',
            )
          : raw === 'flow_agreement_template_required'
            ? t(
                'projects.flows.error_agreement',
                'Amb contracte a part cal triar la plantilla del contracte.',
              )
            : commercialErrorMessage(err, t('common:error', 'Error'))
      toast({ variant: 'destructive', description: msg })
    } finally {
      setBusy(false)
    }
  }

  async function setStatus(row: CommercialQuickFlowRow, status: CommercialQuickFlowStatus) {
    if (!canEdit || busy) return
    setBusy(true)
    try {
      await setCommercialQuickFlowStatus(row.id, status)
      await queryClient.invalidateQueries({ queryKey: ['commercial_quick_flows'] })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    } finally {
      setBusy(false)
    }
  }

  function sourceWarning(row: CommercialQuickFlowRow): string | null {
    if (row.calculator_definition_id) {
      const calc = calcById.get(row.calculator_definition_id)
      if (!calc) return t('projects.flows.warn_calc_missing', 'Calculadora no disponible')
      if (calc.status !== 'active' || !calc.published_version_id) {
        return t('projects.flows.warn_calc_inactive', 'Calculadora inactiva o sense publicar')
      }
    }
    if (row.pricing_template_id) {
      const habit = habitById.get(row.pricing_template_id)
      if (!habit) return t('projects.flows.warn_habit_missing', 'Servei habitual no disponible')
    }
    return null
  }

  return (
    <div className="app-list-column space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold">
            {t('projects.flows.title', 'Fluxos comercials')}
          </h2>
          <p className="text-sm text-muted-foreground">
            {t(
              'projects.flows.help',
              'Preconfigura calculadora o servei habitual, plantilla i formalització per llançar pressupostos ràpids.',
            )}
          </p>
        </div>
        {canEdit ? (
          <Button type="button" onClick={openCreate}>
            <Plus className="mr-1.5 h-4 w-4" />
            {t('projects.flows.create', 'Nou flux')}
          </Button>
        ) : null}
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('common:loading', 'Carregant…')}</p>
      ) : flows.length === 0 ? (
        <p className="rounded-xl border border-dashed border-border px-4 py-8 text-center text-sm text-muted-foreground">
          {t('projects.flows.empty', 'Encara no hi ha fluxos. Crea’n un per llançar pressupostos preconfigurats.')}
        </p>
      ) : (
        <div className="space-y-3">
          {flows.map((row) => {
            const warn = sourceWarning(row)
            return (
              <div
                key={row.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border bg-card px-4 py-3"
              >
                <div className="min-w-0">
                  <p className="font-medium">{row.name}</p>
                  {row.description ? (
                    <p className="text-xs text-muted-foreground">{row.description}</p>
                  ) : null}
                  <div className="mt-1.5 flex flex-wrap gap-1.5 text-[10px] font-medium uppercase">
                    <span className="rounded bg-muted px-2 py-0.5 text-muted-foreground">
                      {row.status}
                    </span>
                    <span className="rounded bg-slate-100 px-2 py-0.5 text-slate-700">
                      {row.calculator_definition_id
                        ? t('projects.flows.source_calc', 'Calculadora')
                        : t('projects.flows.source_habit', 'Hàbit')}
                    </span>
                    <span className="rounded bg-amber-100 px-2 py-0.5 text-amber-800">
                      {row.formalization_mode === 'signed_quote'
                        ? t('projects.flows.mode_signed', 'Pressupost = contracte')
                        : t('projects.flows.mode_separate', 'Contracte a part')}
                    </span>
                    {warn ? (
                      <span className="rounded bg-destructive/10 px-2 py-0.5 text-destructive">
                        {warn}
                      </span>
                    ) : null}
                  </div>
                  {row.formalization_mode === 'separate_agreement' ? (
                    <p className="mt-1 text-xs text-muted-foreground">
                      {t(
                        'projects.flows.separate_note',
                        'El contracte es prepara després d’acceptar el pressupost.',
                      )}
                    </p>
                  ) : null}
                </div>
                <div className="flex flex-wrap gap-2">
                  {row.status === 'active' && canLaunch && !warn ? (
                    <Button type="button" size="sm" onClick={() => setLaunchFlow(row)}>
                      {t('projects.flows.launch', 'Llançar')}
                    </Button>
                  ) : null}
                  {canEdit ? (
                    <>
                      <Button type="button" size="sm" variant="outline" onClick={() => openEdit(row)}>
                        {t('common:edit', 'Editar')}
                      </Button>
                      {row.status !== 'active' ? (
                        <Button
                          type="button"
                          size="sm"
                          variant="secondary"
                          disabled={busy}
                          onClick={() => void setStatus(row, 'active')}
                        >
                          {t('projects.flows.activate', 'Activar')}
                        </Button>
                      ) : (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          disabled={busy}
                          onClick={() => void setStatus(row, 'archived')}
                        >
                          {t('projects.flows.archive', 'Arxivar')}
                        </Button>
                      )}
                    </>
                  ) : null}
                </div>
              </div>
            )
          })}
        </div>
      )}

      <Dialog open={editorOpen} onOpenChange={setEditorOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {editing
                ? t('projects.flows.edit_title', 'Editar flux')
                : t('projects.flows.create_title', 'Nou flux')}
            </DialogTitle>
          </DialogHeader>
          <div className="max-h-[70vh] space-y-3 overflow-y-auto">
            <div className="space-y-1">
              <Label>{t('projects.flows.field_name', 'Nom')}</Label>
              <Input
                value={form.name}
                onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
              />
            </div>
            <div className="space-y-1">
              <Label>{t('projects.flows.field_description', 'Descripció')}</Label>
              <Textarea
                value={form.description}
                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
                rows={2}
              />
            </div>
            <div className="space-y-1">
              <Label>{t('projects.flows.field_source', 'Font')}</Label>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={form.sourceKind}
                onChange={(e) =>
                  setForm((f) => ({
                    ...f,
                    sourceKind: e.target.value as 'calculator' | 'habit',
                  }))
                }
              >
                <option value="calculator">
                  {t('projects.flows.source_calc', 'Calculadora')}
                </option>
                <option value="habit">{t('projects.flows.source_habit', 'Hàbit')}</option>
              </select>
            </div>
            {form.sourceKind === 'calculator' ? (
              <div className="space-y-1">
                <Label>{t('projects.lines.calculator_pick', 'Calculadora')}</Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={form.calculatorDefinitionId}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, calculatorDefinitionId: e.target.value }))
                  }
                >
                  <option value="">{t('projects.lines.calculator_pick_ph', 'Tria…')}</option>
                  {calculators.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </div>
            ) : (
              <div className="space-y-1">
                <Label>{t('projects.lines.template_label', 'Servei habitual')}</Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={form.pricingTemplateId}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, pricingTemplateId: e.target.value }))
                  }
                >
                  <option value="">
                    {t('projects.lines.template_placeholder', 'Selecciona…')}
                  </option>
                  {habits.map((h) => (
                    <option key={h.id} value={h.id}>
                      {h.name}
                    </option>
                  ))}
                </select>
              </div>
            )}
            <div className="space-y-1">
              <Label>{t('projects.flows.field_quote_template', 'Plantilla de pressupost')}</Label>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={form.quoteTemplateId}
                onChange={(e) => setForm((f) => ({ ...f, quoteTemplateId: e.target.value }))}
              >
                <option value="">{t('projects.lines.calculator_pick_ph', 'Tria…')}</option>
                {quoteTemplates.map((tpl) => (
                  <option key={tpl.id!} value={tpl.id!}>
                    {tpl.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <Label>{t('projects.flows.field_formalization', 'Formalització')}</Label>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={form.formalizationMode}
                onChange={(e) =>
                  setForm((f) => ({
                    ...f,
                    formalizationMode: e.target.value as FormalizationMode,
                  }))
                }
              >
                <option value="signed_quote">
                  {t('projects.flows.mode_signed', 'Pressupost = contracte')}
                </option>
                <option value="separate_agreement">
                  {t('projects.flows.mode_separate', 'Contracte a part')}
                </option>
              </select>
            </div>
            {form.formalizationMode === 'separate_agreement' ? (
              <div className="space-y-1">
                <Label>
                  {t('projects.flows.field_agreement_template', 'Plantilla de contracte')}
                </Label>
                <select
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={form.agreementTemplateId}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, agreementTemplateId: e.target.value }))
                  }
                >
                  <option value="">{t('projects.lines.calculator_pick_ph', 'Tria…')}</option>
                  {agreementTemplates.map((tpl) => (
                    <option key={tpl.id!} value={tpl.id!}>
                      {tpl.name}
                      {tpl.is_platform_default ? ' (sistema)' : ''}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'projects.flows.separate_note',
                    'El contracte es prepara després d’acceptar el pressupost.',
                  )}
                </p>
              </div>
            ) : null}
            <div className="space-y-1">
              <Label>{t('projects.flows.field_status', 'Estat')}</Label>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={form.status}
                onChange={(e) =>
                  setForm((f) => ({
                    ...f,
                    status: e.target.value as CommercialQuickFlowStatus,
                  }))
                }
              >
                <option value="draft">draft</option>
                <option value="active">active</option>
                <option value="archived">archived</option>
              </select>
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setEditorOpen(false)}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              disabled={busy || !form.name.trim() || !form.quoteTemplateId}
              onClick={() => void save()}
            >
              {t('common:save', 'Desar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {launchFlow ? (
        <LaunchCommercialFlowDialog
          open={!!launchFlow}
          onOpenChange={(next) => {
            if (!next) setLaunchFlow(null)
          }}
          flow={launchFlow}
        />
      ) : null}
    </div>
  )
}
